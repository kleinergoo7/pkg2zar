// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include <QApplication>
#include <QCheckBox>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFileDialog>
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
    void testClickConvert() { convertButton_->click(); }
    void testClickCancel() { cancelButton_->click(); }
    bool testBusy() const { return running_.load(); }
    QString testLog() const { return log_->toPlainText(); }

protected:
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private:
    void addInputs(const QStringList &paths);
    void pickInputs();
    void pickOutput();
    void start();
    void cancel();
    void poll();
    void log(const QString &line);
    void logFromWorker(const QString &line);
    static std::string siblingArchive(const std::string &output, const std::string &input);
    void setBusy(bool busy);
    void updateOutputDefault();

    QListWidget *inputs_;
    QLineEdit *output_;
    QPushButton *addButton_;
    QPushButton *browseButton_;
    QPushButton *convertButton_;
    QPushButton *cancelButton_;
    QCheckBox *separateBox_;
    QProgressBar *progress_;
    QLabel *currentFile_;
    QPlainTextEdit *log_;

    std::thread worker_;
    ProgressState progressState_;
    std::array<char, 512> error_{};
    std::atomic<int> result_{0};
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> last_percent{255};
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
        if (!existing.contains(path)) {
            inputs_->addItem(path);
            existing << path;
        }
    }
    if (inputs_->count() > 2) {
        log(QStringLiteral("More than two inputs selected; only the first two are used."));
    }
    updateOutputDefault();
}

void MainWindow::pickInputs() {
    const QStringList paths = QFileDialog::getOpenFileNames(
        this, QStringLiteral("Select pkg files"), QString(),
        QStringLiteral("PS4 packages (*.pkg);;All files (*)"));
    addInputs(paths);
}

void MainWindow::pickOutput() {
    const QString path = QFileDialog::getSaveFileName(
        this, QStringLiteral("Save archive"), output_->text(),
        QStringLiteral("shadPS4 archives (*.zar)"));
    if (!path.isEmpty()) {
        output_->setText(path);
    }
}

void MainWindow::updateOutputDefault() {
    if (inputs_->count() == 0 || !output_->text().isEmpty()) {
        return;
    }
    QFileInfo info(inputs_->item(0)->text());
    output_->setText(info.absolutePath() + "/" + info.completeBaseName() + ".zar");
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

    // Ask before replacing anything; the core renames over the old file only after verify.
    std::vector<std::string> targets;
    if (separate) {
        for (const std::string &input : owned) {
            targets.push_back(siblingArchive(outputUtf8, input));
        }
    } else {
        targets.push_back(outputUtf8);
    }
    bool overwrite = false;
    size_t existing = 0;
    for (const std::string &target : targets) {
        if (QFileInfo::exists(QString::fromStdString(target))) {
            ++existing;
        }
    }
    if (existing > 0) {
        const QString text =
            existing == 1
                ? QStringLiteral("The output file already exists:\n%1\n\nReplace it?")
                      .arg(QString::fromStdString(targets.back()))
                : QStringLiteral("%1 output files already exist. Replace them?").arg(existing);
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

    worker_ = std::thread([this, owned, outputUtf8, separate, overwrite] {
        int code = P2Z_OK;
        if (separate) {
            for (const std::string &input : owned) {
                std::string out = siblingArchive(outputUtf8, input);
                std::vector<const char *> pointers{input.c_str()};
                logFromWorker(QStringLiteral("Converting %1 -> %2")
                                  .arg(QString::fromStdString(input), QString::fromStdString(out)));
                progressState_.done.store(0);
                progressState_.total.store(0);
                code = p2z_run(P2Z_MODE_SINGLE, overwrite ? 1 : 0, out.c_str(), pointers.data(), 1,
                               progressCallback, &progressState_, error_.data(), error_.size());
                if (code != P2Z_OK) {
                    break;
                }
            }
        } else {
            std::vector<const char *> pointers;
            pointers.reserve(owned.size());
            for (const std::string &path : owned) {
                pointers.push_back(path.c_str());
            }
            code = p2z_run(P2Z_MODE_AUTO, overwrite ? 1 : 0, outputUtf8.c_str(), pointers.data(),
                           owned.size(), progressCallback, &progressState_, error_.data(),
                           error_.size());
        }
        result_.store(code);
        running_.store(false);
    });
}

/* Writes to the log from the worker thread through a queued call. */
void MainWindow::logFromWorker(const QString &line) {
    QMetaObject::invokeMethod(this, [this, line] { log(line); }, Qt::QueuedConnection);
}

/* Derives `dir/<input base name>.zar` from the chosen output directory. */
std::string MainWindow::siblingArchive(const std::string &output, const std::string &input) {
    std::string dir = output;
    const size_t slash = dir.find_last_of("/\\");
    dir = slash == std::string::npos ? std::string() : dir.substr(0, slash + 1);
    std::string name = input;
    const size_t islash = name.find_last_of("/\\");
    if (islash != std::string::npos) {
        name = name.substr(islash + 1);
    }
    const size_t dot = name.find_last_of('.');
    if (dot != std::string::npos) {
        name = name.substr(0, dot);
    }
    return dir + name + ".zar";
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
static std::string siblingArchive(const std::string &output, const std::string &input) {
    std::string dir = output;
    const size_t slash = dir.find_last_of("/\\");
    dir = slash == std::string::npos ? std::string() : dir.substr(0, slash + 1);
    std::string name = input;
    const size_t islash = name.find_last_of("/\\");
    if (islash != std::string::npos) {
        name = name.substr(islash + 1);
    }
    const size_t dot = name.find_last_of('.');
    if (dot != std::string::npos) {
        name = name.substr(0, dot);
    }
    return dir + name + ".zar";
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
        const int code = p2z_run(P2Z_MODE_AUTO, 0, output.c_str(), pointers.data(), pointers.size(),
                                 nullptr, nullptr, err, sizeof(err));
        if (code != P2Z_OK) {
            std::fprintf(stderr, "%s\n", err);
        }
        return code;
    }
    for (const std::string &input : owned) {
        const std::string out = siblingArchive(output, input);
        const char *pointer = input.c_str();
        char err[512] = {0};
        const int code = p2z_run(P2Z_MODE_SINGLE, 0, out.c_str(), &pointer, 1, nullptr, nullptr, err,
                                 sizeof(err));
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
    window.testSetInputs(inputs);
    window.testSetOutput(output);
    window.testSetSeparate(mode == "separate");

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
        } else if (mode == "separate") {
            require(window.testLog().contains(QStringLiteral("Done")), QStringLiteral("log has no Done line"));
            for (const QString &input : inputs) {
                const QString derived =
                    QString::fromStdString(siblingArchive(output.toStdString(), input.toStdString()));
                require(QFileInfo::exists(derived), QStringLiteral("derived archive missing: ") + derived);
            }
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
            if (mode == "cancel" && !cancelSent && clock.elapsed() > 800) {
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
