// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFileDialog>
#include <QDir>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMainWindow>
#include <QMessageBox>
#include <QMimeData>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QElapsedTimer>
#include <QTimer>
#include <QVBoxLayout>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "p2z.h"

struct InputInfo {
    QString title;
    QString titleId;
    QString version;
    bool patch = false;
    bool ok = false;
};

static InputInfo probePath(const QString &path);
static QString defaultName(const InputInfo &info, int role, bool extract);
static std::string dirOf(const std::string &path);

struct ProgressState {
    std::atomic<uint64_t> done{0};
    std::atomic<uint64_t> total{0};
    std::mutex mutex;
    std::string current;
};

static void progressCallback(void *ctx, uint64_t done, uint64_t total, const char *current,
                             size_t currentLen) {
    auto *state = static_cast<ProgressState *>(ctx);
    if (state == nullptr) {
        return;
    }
    state->done.store(done, std::memory_order_relaxed);
    state->total.store(total, std::memory_order_relaxed);
    if (current != nullptr) {
        std::lock_guard<std::mutex> guard(state->mutex);
        state->current.assign(current, currentLen);
    }
}

class MainWindow : public QMainWindow {
public:
    MainWindow();

    /* Hooks for the offscreen UI self-test. They drive the same widgets a user clicks. */
    void testSetInputs(const QStringList &paths) { addInputs(paths); }
    void testSetOutput(const QString &path) { output_->setText(path); }
    void testSetSeparate(bool on) { separateBox_->setChecked(on); }
    void testSetKind(bool extract) { kindBox_->setCurrentIndex(extract ? 1 : 0); }
    void testClickConvert() { convertButton_->click(); }
    void testClickCancel() { cancelButton_->click(); }
    bool testBusy() const { return running_.load(); }
    QString testLog() const { return log_->toPlainText(); }
    QString testOutput() const { return output_->text(); }

protected:
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private:
    void addInputs(const QStringList &paths);
    InputInfo infoOf(int index) const;
    int roleFor(const InputInfo &info) const;
    void pickInputs();
    void pickOutput();
    bool extractMode() const;
    void start();
    void cancel();
    void poll();
    void log(const QString &line);
    void logFromWorker(const QString &line);
    void setBusy(bool busy);
    void updateOutputDefault();

    QListWidget *inputs_;
    QLineEdit *output_;
    QPushButton *addButton_;
    QPushButton *browseButton_;
    QPushButton *convertButton_;
    QPushButton *cancelButton_;
    QCheckBox *separateBox_;
    QComboBox *kindBox_;
    QProgressBar *progress_;
    QLabel *currentFile_;
    QPlainTextEdit *log_;

    std::thread worker_;
    ProgressState progressState_;
    std::array<char, 512> error_{};
    std::atomic<int> result_{0};
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> last_percent{255};
    bool outputEdited_ = false;
    QTimer timer_;
};

MainWindow::MainWindow() {
    setWindowTitle("ps4-pkg2zar");
    setAcceptDrops(true);
    resize(760, 560);

    auto *central = new QWidget(this);
    auto *layout = new QVBoxLayout(central);

    layout->addWidget(new QLabel(QStringLiteral("Packages (one to convert, base + update to merge):")));
    inputs_ = new QListWidget(central);
    inputs_->setSelectionMode(QAbstractItemView::ExtendedSelection);
    layout->addWidget(inputs_, 2);

    auto *inputButtons = new QHBoxLayout();
    addButton_ = new QPushButton(QStringLiteral("Add files..."), central);
    auto *removeButton = new QPushButton(QStringLiteral("Remove selected"), central);
    inputButtons->addWidget(addButton_);
    inputButtons->addWidget(removeButton);
    inputButtons->addStretch();
    layout->addLayout(inputButtons);

    auto *outputRow = new QHBoxLayout();
    outputRow->addWidget(new QLabel(QStringLiteral("Output:")));
    kindBox_ = new QComboBox(central);
    kindBox_->addItem(QStringLiteral("Archive (.zar)"));
    kindBox_->addItem(QStringLiteral("Extract to folder"));
    outputRow->addWidget(kindBox_);
    output_ = new QLineEdit(central);
    browseButton_ = new QPushButton(QStringLiteral("Browse..."), central);
    outputRow->addWidget(output_, 1);
    outputRow->addWidget(browseButton_);
    layout->addLayout(outputRow);

    progress_ = new QProgressBar(central);
    progress_->setRange(0, 1000);
    layout->addWidget(progress_);

    currentFile_ = new QLabel(central);
    currentFile_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    layout->addWidget(currentFile_);

    separateBox_ = new QCheckBox(QStringLiteral("Convert each input separately (no merge)"), central);
    layout->addWidget(separateBox_);

    auto *actions = new QHBoxLayout();
    convertButton_ = new QPushButton(QStringLiteral("Convert"), central);
    cancelButton_ = new QPushButton(QStringLiteral("Cancel"), central);
    cancelButton_->setEnabled(false);
    actions->addWidget(convertButton_);
    actions->addWidget(cancelButton_);
    actions->addStretch();
    layout->addLayout(actions);

    log_ = new QPlainTextEdit(central);
    log_->setReadOnly(true);
    layout->addWidget(log_, 2);

    setCentralWidget(central);

    connect(addButton_, &QPushButton::clicked, this, [this] { pickInputs(); });
    connect(removeButton, &QPushButton::clicked, this, [this] {
        qDeleteAll(inputs_->selectedItems());
        updateOutputDefault();
    });
    connect(browseButton_, &QPushButton::clicked, this, [this] { pickOutput(); });
    connect(convertButton_, &QPushButton::clicked, this, [this] { start(); });
    connect(cancelButton_, &QPushButton::clicked, this, [this] { cancel(); });
    connect(output_, &QLineEdit::textEdited, this, [this] { outputEdited_ = true; });
    connect(kindBox_, &QComboBox::currentIndexChanged, this, [this] {
        outputEdited_ = false;
        updateOutputDefault();
    });
    connect(separateBox_, &QCheckBox::toggled, this, [this] {
        outputEdited_ = false;
        updateOutputDefault();
    });
    connect(&timer_, &QTimer::timeout, this, [this] { poll(); });
    timer_.setInterval(100);

    const uint32_t abi = p2z_abi_version();
    if (abi != P2Z_ABI_VERSION) {
        std::fprintf(stderr, "ABI mismatch: core %u, header %u\n", abi, P2Z_ABI_VERSION);
        log(QStringLiteral("ABI mismatch: core %1, header %2. Rebuild both.").arg(abi).arg(P2Z_ABI_VERSION));
        convertButton_->setEnabled(false);
        return;
    }
    log(QStringLiteral("Drop .pkg files here, or use Add files. Two inputs merge, one converts."));
}

void MainWindow::dragEnterEvent(QDragEnterEvent *event) {
    if (event->mimeData()->hasUrls()) {
        event->acceptProposedAction();
    }
}

void MainWindow::dropEvent(QDropEvent *event) {
    QStringList paths;
    for (const QUrl &url : event->mimeData()->urls()) {
        const QString local = url.toLocalFile();
        if (local.endsWith(QStringLiteral(".pkg"), Qt::CaseInsensitive)) {
            paths << local;
        }
    }
    if (!paths.isEmpty()) {
        addInputs(paths);
        event->acceptProposedAction();
    }
}

void MainWindow::addInputs(const QStringList &paths) {
    if (running_.load()) {
        return;
    }
    QStringList existing;
    for (int i = 0; i < inputs_->count(); ++i) {
        existing << inputs_->item(i)->text();
    }
    for (const QString &path : paths) {
        if (existing.contains(path)) {
            continue;
        }
        auto *item = new QListWidgetItem(path);
        const InputInfo info = probePath(path);
        QVariantMap data;
        data.insert(QStringLiteral("title"), info.title);
        data.insert(QStringLiteral("id"), info.titleId);
        data.insert(QStringLiteral("version"), info.version);
        data.insert(QStringLiteral("patch"), info.patch);
        data.insert(QStringLiteral("ok"), info.ok);
        item->setData(Qt::UserRole, data);
        inputs_->addItem(item);
        existing << path;
        if (info.ok) {
            log(QStringLiteral("%1: %2 (%3) v%4%5")
                    .arg(path, info.title, info.titleId, info.version,
                         info.patch ? QStringLiteral(" [patch]") : QString()));
        } else {
            log(QStringLiteral("%1: could not read title, using the file name").arg(path));
        }
    }
    if (inputs_->count() > 2) {
        log(QStringLiteral("More than two inputs selected; only the first two are used."));
    }
    updateOutputDefault();
}

InputInfo MainWindow::infoOf(int index) const {
    InputInfo info;
    if (index < 0 || index >= inputs_->count()) {
        return info;
    }
    const QVariantMap data = inputs_->item(index)->data(Qt::UserRole).toMap();
    info.title = data.value(QStringLiteral("title")).toString();
    info.titleId = data.value(QStringLiteral("id")).toString();
    info.version = data.value(QStringLiteral("version")).toString();
    info.patch = data.value(QStringLiteral("patch")).toBool();
    info.ok = data.value(QStringLiteral("ok")).toBool();
    return info;
}

int MainWindow::roleFor(const InputInfo &info) const {
    if (separateBox_->isChecked() && inputs_->count() > 1) {
        return info.patch ? P2Z_ROLE_UPDATE : P2Z_ROLE_BASE;
    }
    if (inputs_->count() > 1) {
        return P2Z_ROLE_MERGED;
    }
    return P2Z_ROLE_SINGLE;
}

void MainWindow::pickInputs() {
    const QStringList paths = QFileDialog::getOpenFileNames(
        this, QStringLiteral("Select pkg files"), QString(),
        QStringLiteral("PS4 packages (*.pkg);;All files (*)"));
    addInputs(paths);
}

bool MainWindow::extractMode() const {
    return kindBox_->currentIndex() == 1;
}

void MainWindow::pickOutput() {
    const QString path =
        extractMode() ? QFileDialog::getExistingDirectory(this, QStringLiteral("Choose output folder"),
                                                          output_->text())
                      : QFileDialog::getSaveFileName(this, QStringLiteral("Save archive"), output_->text(),
                                                     QStringLiteral("shadPS4 archives (*.zar)"));
    if (!path.isEmpty()) {
        output_->setText(path);
    }
}

void MainWindow::updateOutputDefault() {
    if (inputs_->count() == 0) {
        return;
    }
    const bool separate = separateBox_->isChecked() && inputs_->count() > 1;
    const QString firstPath = inputs_->item(0)->text();
    QFileInfo firstFile(firstPath);

    if (separate) {
        if (!outputEdited_ || output_->text().isEmpty()) {
            output_->setText(firstFile.absolutePath());
            outputEdited_ = false;
        }
        return;
    }
    if (outputEdited_ && !output_->text().isEmpty()) {
        return;
    }

    // For a merge, take the name from the update: it wins every conflicting file.
    int chosen = 0;
    if (inputs_->count() > 1) {
        for (int i = 0; i < inputs_->count(); ++i) {
            if (infoOf(i).patch) {
                chosen = i;
                break;
            }
        }
    }
    const InputInfo info = infoOf(chosen);
    QString name;
    if (info.ok) {
        name = defaultName(info, inputs_->count() > 1 ? P2Z_ROLE_MERGED : P2Z_ROLE_SINGLE, extractMode());
    }
    if (name.isEmpty()) {
        name = firstFile.completeBaseName() + (extractMode() ? QString() : QStringLiteral(".zar"));
    }
    output_->setText(firstFile.absolutePath() + "/" + name);
    outputEdited_ = false;
}

void MainWindow::setBusy(bool busy) {
    running_.store(busy);
    convertButton_->setEnabled(!busy);
    cancelButton_->setEnabled(busy);
    addButton_->setEnabled(!busy);
    inputs_->setEnabled(!busy);
    browseButton_->setEnabled(!busy);
    output_->setReadOnly(busy);
}

void MainWindow::start() {
    if (running_.load()) {
        return;
    }
    if (inputs_->count() == 0) {
        log(QStringLiteral("No input selected."));
        return;
    }
    if (inputs_->count() > 2) {
        log(QStringLiteral("Select at most two pkgs: a base and an update."));
        return;
    }
    const QString output = output_->text().trimmed();
    if (output.isEmpty()) {
        log(QStringLiteral("Choose an output path."));
        return;
    }

    std::vector<std::string> owned;
    owned.reserve(inputs_->count());
    for (int i = 0; i < inputs_->count(); ++i) {
        owned.push_back(inputs_->item(i)->text().toStdString());
    }
    const std::string outputUtf8 = output.toStdString();
    const bool separate = separateBox_->isChecked() && owned.size() > 1;
    const bool extract = extractMode();
    const int kind = extract ? P2Z_KIND_EXTRACT : P2Z_KIND_ARCHIVE;

    // Build the jobs: one merged/convert job, or one job per input in separate mode.
    struct Job {
        std::vector<std::string> inputs;
        std::string output;
    };
    std::vector<Job> jobs;
    if (separate) {
        std::string dir = outputUtf8;
        if (!QFileInfo(QString::fromStdString(outputUtf8)).isDir()) {
            dir = dirOf(outputUtf8);
        }
        if (!dir.empty() && dir.back() != '/') {
            dir.push_back('/');
        }
        for (int i = 0; i < inputs_->count(); ++i) {
            const InputInfo info = infoOf(i);
            QString name = info.ok ? defaultName(info, roleFor(info), extract)
                                   : QString::fromStdString(owned[static_cast<size_t>(i)]);
            if (name.isEmpty()) {
                name = QFileInfo(inputs_->item(i)->text()).completeBaseName() +
                       (extract ? QString() : QStringLiteral(".zar"));
            }
            if (!extract && !name.endsWith(QStringLiteral(".zar"))) {
                name += QStringLiteral(".zar");
            }
            jobs.push_back({{owned[static_cast<size_t>(i)]}, dir + name.toStdString()});
        }
    } else {
        jobs.push_back({owned, outputUtf8});
    }

    // Ask before replacing anything; the core renames over the old file only after verify.
    std::vector<std::string> targets;
    for (const Job &job : jobs) {
        targets.push_back(job.output);
    }
    bool overwrite = false;
    size_t existing = 0;
    for (const std::string &target : targets) {
        if (QFileInfo::exists(QString::fromStdString(target))) {
            ++existing;
        }
    }
    if (existing > 0) {
        const QString noun = extract ? QStringLiteral("folder") : QStringLiteral("file");
        const QString text =
            existing == 1
                ? QStringLiteral("The output %1 already exists:\n%2\n\nReplace it?")
                      .arg(noun, QString::fromStdString(targets.back()))
                : QStringLiteral("%1 output %2s already exist. Replace them?").arg(existing).arg(noun);
        const auto answer = QMessageBox::question(this, QStringLiteral("Replace existing archive"), text,
                                                  QMessageBox::Yes | QMessageBox::No | QMessageBox::Cancel,
                                                  QMessageBox::No);
        if (answer == QMessageBox::Cancel) {
            return;
        }
        if (answer == QMessageBox::No) {
            log(QStringLiteral("Choose a different output name or folder, then start again."));
            pickOutput();
            return;
        }
        overwrite = true;
    }

    progressState_.done.store(0);
    progressState_.total.store(0);
    error_.fill(0);
    result_.store(0);
    progress_->setValue(0);
    currentFile_->clear();
    last_percent.store(255);

    setBusy(true);
    timer_.start();
    log(separate ? QStringLiteral("Starting separate conversion of %1 files...").arg(owned.size())
                 : QStringLiteral("Starting %1...").arg(owned.size() == 2 ? "merge" : "convert"));

    worker_ = std::thread([this, jobs, overwrite, kind, separate] {
        int code = P2Z_OK;
        for (const Job &job : jobs) {
            std::vector<const char *> pointers;
            pointers.reserve(job.inputs.size());
            for (const std::string &path : job.inputs) {
                pointers.push_back(path.c_str());
            }
            if (separate) {
                logFromWorker(QStringLiteral("Converting %1 -> %2")
                                  .arg(QString::fromStdString(job.inputs.front()),
                                       QString::fromStdString(job.output)));
                progressState_.done.store(0);
                progressState_.total.store(0);
            }
            const int mode = separate ? P2Z_MODE_SINGLE : P2Z_MODE_AUTO;
            code = p2z_run(mode, kind, overwrite ? 1 : 0, job.output.c_str(), pointers.data(),
                           pointers.size(), progressCallback, &progressState_, error_.data(),
                           error_.size());
            if (code != P2Z_OK) {
                break;
            }
        }
        result_.store(code);
        running_.store(false);
    });
}

/* Writes to the log from the worker thread through a queued call. */
void MainWindow::logFromWorker(const QString &line) {
    QMetaObject::invokeMethod(this, [this, line] { log(line); }, Qt::QueuedConnection);
}

void MainWindow::cancel() {
    if (!running_.load()) {
        return;
    }
    p2z_cancel();
    log(QStringLiteral("Cancelling..."));
}

void MainWindow::poll() {
    const uint64_t total = progressState_.total.load(std::memory_order_relaxed);
    const uint64_t done = progressState_.done.load(std::memory_order_relaxed);
    if (total > 0) {
        progress_->setValue(static_cast<int>(done * 1000 / total));
    }
    std::string current;
    {
        std::lock_guard<std::mutex> guard(progressState_.mutex);
        current = progressState_.current;
    }
    if (!current.empty()) {
        currentFile_->setText(QString::fromStdString(current));
    }

    if (running_.load()) {
        return;
    }
    timer_.stop();
    if (worker_.joinable()) {
        worker_.join();
    }
    progress_->setValue(result_.load() == P2Z_OK ? 1000 : progress_->value());
    switch (result_.load()) {
    case P2Z_OK:
        log(QStringLiteral("Done: %1").arg(output_->text()));
        if (error_[0] != 0) {
            log(QString::fromUtf8(error_.data()));
        }
        break;
    case P2Z_CANCELLED:
        log(QStringLiteral("Cancelled. No archive written."));
        break;
    default:
        log(QStringLiteral("Failed: %1").arg(QString::fromUtf8(error_.data())));
        break;
    }
    setBusy(false);
}

void MainWindow::log(const QString &line) {
    log_->appendPlainText(line);
}

/* Headless path used by the build gate: `ps4-pkg2zar --run out.zar in.pkg [update.pkg]`. */
static std::string dirOf(const std::string &path) {
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? std::string() : path.substr(0, slash + 1);
}

static InputInfo probePath(const QString &path) {
    InputInfo info;
    QByteArray title(256, 0);
    QByteArray id(64, 0);
    QByteArray version(64, 0);
    char err[256] = {0};
    int patch = 0;
    const QByteArray native = path.toLocal8Bit();
    const int code = p2z_probe(native.constData(), title.data(), title.size(), id.data(), id.size(),
                               version.data(), version.size(), &patch, err, sizeof(err));
    if (code != 0) {
        return info;
    }
    info.title = QString::fromUtf8(title.constData());
    info.titleId = QString::fromUtf8(id.constData());
    info.version = QString::fromUtf8(version.constData());
    info.patch = patch != 0;
    info.ok = true;
    return info;
}

static QString defaultName(const InputInfo &info, int role, bool extract) {
    char name[512] = {0};
    const QByteArray title = info.title.toUtf8();
    const QByteArray id = info.titleId.toUtf8();
    const QByteArray version = info.version.toUtf8();
    if (p2z_output_name(role, title.constData(), id.constData(), version.constData(), extract ? 1 : 0,
                        name, sizeof(name)) != 0) {
        return QString();
    }
    return QString::fromUtf8(name);
}

static int runHeadless(bool separate, int argc, char **argv) {
    const std::string output = argv[2];
    std::vector<std::string> owned;
    for (int i = 3; i < argc; ++i) {
        owned.emplace_back(argv[i]);
    }
    if (!separate) {
        std::vector<const char *> pointers;
        for (const std::string &path : owned) {
            pointers.push_back(path.c_str());
        }
        char err[512] = {0};
        const int code = p2z_run(P2Z_MODE_AUTO, P2Z_KIND_ARCHIVE, 0, output.c_str(), pointers.data(),
                                 pointers.size(), nullptr, nullptr, err, sizeof(err));
        if (code != P2Z_OK) {
            std::fprintf(stderr, "%s\n", err);
        }
        return code;
    }
    for (const std::string &input : owned) {
        const std::string out = dirOf(output) + QFileInfo(QString::fromStdString(input)).completeBaseName().toStdString() + ".zar";
        const char *pointer = input.c_str();
        char err[512] = {0};
        const int code = p2z_run(P2Z_MODE_SINGLE, P2Z_KIND_ARCHIVE, 0, out.c_str(), &pointer, 1, nullptr,
                                 nullptr, err, sizeof(err));
        if (code != P2Z_OK) {
            std::fprintf(stderr, "%s: %s\n", input.c_str(), err);
            return code;
        }
        std::fprintf(stderr, "wrote %s\n", out.c_str());
    }
    return P2Z_OK;
}

/* Offscreen self-test: drives the real widgets, then checks the log and the files.
 * Usage: --ui-selftest <convert|merge|cancel|separate> <out.zar> <in.pkg> [in2.pkg] */
static int runUiSelfTest(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: --ui-selftest <convert|merge|cancel|separate> <out> <in...>\n");
        return 2;
    }
    const std::string mode = argv[2];
    const QString output = QString::fromLocal8Bit(argv[3]);
    QStringList inputs;
    for (int i = 4; i < argc; ++i) {
        inputs << QString::fromLocal8Bit(argv[i]);
    }

    const QString part = output + QStringLiteral(".part");
    QFile::remove(output);
    QFile::remove(part);

    MainWindow window;
    window.show();

    if (mode == "name" || mode == "name-merged") {
        window.testSetInputs(inputs);
        QTimer::singleShot(300, [&] {
            const QString name = window.testOutput();
            QStringList problems;
            if (!name.contains(QStringLiteral("Terraria (CUSA00740)"))) {
                problems << QStringLiteral("title or id missing");
            }
            if (mode == "name" && name.contains(QStringLiteral(" - "))) {
                problems << QStringLiteral("single name has a role suffix");
            }
            if (mode == "name-merged" && !name.contains(QStringLiteral(" - merged"))) {
                problems << QStringLiteral("merge name has no - merged suffix");
            }
            if (!name.endsWith(QStringLiteral(".zar"))) {
                problems << QStringLiteral("no .zar suffix");
            }
            if (!problems.isEmpty()) {
                std::fprintf(stderr, "UI SELFTEST FAIL: %s (got '%s')\n",
                             qPrintable(problems.join(QStringLiteral(", "))), qPrintable(name));
                QCoreApplication::exit(1);
                return;
            }
            std::fprintf(stderr, "UI SELFTEST PASS: %s -> %s\n", mode.c_str(), qPrintable(name));
            QCoreApplication::exit(0);
        });
        return QApplication::exec();
    }

    window.show();
    // Configure kind and the separate box before the inputs, so the auto-naming runs last.
    window.testSetKind(mode == "extract");
    window.testSetSeparate(mode == "separate");
    window.testSetInputs(inputs);
    window.testSetOutput(output);

    QElapsedTimer clock;
    clock.start();
    bool cancelSent = false;
    int failures = 0;

    auto finish = [&](const QString &reason) {
        const QString log = window.testLog();
        bool ok = true;
        auto require = [&](bool condition, const QString &what) {
            if (!condition) {
                ok = false;
                std::fprintf(stderr, "UI SELFTEST FAIL: %s\n", qPrintable(what));
            }
        };
        if (mode == "cancel") {
            require(log.contains(QStringLiteral("Cancelled")), QStringLiteral("log has no Cancelled line"));
            require(!QFileInfo::exists(output), QStringLiteral("archive exists after cancel"));
            require(!QFileInfo::exists(part), QStringLiteral(".part exists after cancel"));
        } else if (mode == "swap") {
            require(log.contains(QStringLiteral("Done")), QStringLiteral("log has no Done line"));
            require(log.contains(QStringLiteral("swapped")), QStringLiteral("log has no swap note"));
            require(QFileInfo::exists(output), QStringLiteral("archive missing"));
        } else if (mode == "extract") {
            require(log.contains(QStringLiteral("Done")), QStringLiteral("log has no Done line"));
            require(QFileInfo(output).isDir(), QStringLiteral("output folder missing"));
            require(QFileInfo::exists(output + QStringLiteral("/eboot.bin")), QStringLiteral("eboot.bin missing"));
            require(!QFileInfo::exists(part), QStringLiteral(".part left behind"));
        } else if (mode == "separate") {
            require(log.count(QStringLiteral("Converting")) == inputs.size(),
                    QStringLiteral("log does not show one conversion per input"));
            require(log.contains(QStringLiteral("Done")), QStringLiteral("log has no Done line"));
            const QDir dir(QFileInfo(output).absolutePath());
            const auto list = dir.entryList(QStringList{QStringLiteral("*.zar")}, QDir::Files);
            require(list.size() >= inputs.size(), QStringLiteral("fewer archives than inputs"));
        } else {
            require(log.contains(QStringLiteral("Done")), QStringLiteral("log has no Done line"));
            require(QFileInfo::exists(output), QStringLiteral("archive missing"));
            require(!QFileInfo::exists(part), QStringLiteral(".part left behind"));
        }
        if (failures > 0) {
            ok = false;
        }
        std::fprintf(stderr, "UI SELFTEST %s: %s\n", ok ? "PASS" : "FAIL", qPrintable(reason));
        if (!ok) {
            std::fprintf(stderr, "log:\n%s\n", qPrintable(log));
            QCoreApplication::exit(1);
        } else {
            QCoreApplication::exit(0);
        }
    };

    QTimer poll;
    poll.setInterval(100);
    QObject::connect(&poll, &QTimer::timeout, [&] {
        if (window.testBusy()) {
            if (mode == "cancel" && !cancelSent && clock.elapsed() > 300) {
                window.testClickCancel();
                cancelSent = true;
            }
            if (clock.elapsed() > 180000) {
                finish(QStringLiteral("timeout"));
            }
            return;
        }
        poll.stop();
        finish(QStringLiteral("finished"));
    });

    QTimer::singleShot(150, [&] {
        window.testClickConvert();
        if (!window.testBusy()) {
            finish(QStringLiteral("job did not start"));
            return;
        }
        poll.start();
    });

    return QApplication::exec();
}

int main(int argc, char **argv) {
    if (argc >= 5 && std::strcmp(argv[1], "--ui-selftest") == 0) {
        QApplication app(argc, argv);
        return runUiSelfTest(argc, argv);
    }
    if (argc >= 4 && std::strcmp(argv[1], "--run") == 0) {
        return runHeadless(false, argc, argv);
    }
    if (argc >= 4 && std::strcmp(argv[1], "--run-separate") == 0) {
        return runHeadless(true, argc, argv);
    }
    QApplication app(argc, argv);
    MainWindow window;
    window.show();
    return app.exec();
}
