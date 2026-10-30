// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include <QApplication>
#include <QComboBox>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMainWindow>
#include <QMimeData>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QTimer>
#include <QVBoxLayout>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "p2z.h"

struct ProgressState {
    std::atomic<uint64_t> done{0};
    std::atomic<uint64_t> total{0};
};

static void progressCallback(void *ctx, uint64_t done, uint64_t total) {
    auto *state = static_cast<ProgressState *>(ctx);
    if (state == nullptr) {
        return;
    }
    state->done.store(done, std::memory_order_relaxed);
    state->total.store(total, std::memory_order_relaxed);
}

class MainWindow : public QMainWindow {
public:
    MainWindow();

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
    void setBusy(bool busy);
    void updateOutputDefault();

    QListWidget *inputs_;
    QLineEdit *output_;
    QPushButton *addButton_;
    QPushButton *browseButton_;
    QPushButton *convertButton_;
    QPushButton *cancelButton_;
    QProgressBar *progress_;
    QPlainTextEdit *log_;

    std::thread worker_;
    ProgressState progressState_;
    std::array<char, 512> error_{};
    std::atomic<int> result_{0};
    std::atomic<bool> running_{false};
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
    const size_t count = owned.size();

    progressState_.done.store(0);
    progressState_.total.store(0);
    error_.fill(0);
    result_.store(0);
    progress_->setValue(0);

    setBusy(true);
    timer_.start();
    log(QStringLiteral("Starting %1...").arg(count == 2 ? "merge" : "convert"));

    worker_ = std::thread([this, owned, outputUtf8, count] {
        std::vector<const char *> pointers;
        pointers.reserve(count);
        for (const std::string &path : owned) {
            pointers.push_back(path.c_str());
        }
        const int code = p2z_run(outputUtf8.c_str(), pointers.data(), count, progressCallback,
                                 &progressState_, error_.data(), error_.size());
        result_.store(code);
        running_.store(false);
    });
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
static int runHeadless(int argc, char **argv) {
    const char *output = argv[2];
    std::vector<const char *> inputs;
    for (int i = 3; i < argc; ++i) {
        inputs.push_back(argv[i]);
    }
    char err[512] = {0};
    const int code = p2z_run(output, inputs.data(), inputs.size(), nullptr, nullptr, err, sizeof(err));
    if (code != P2Z_OK) {
        std::fprintf(stderr, "%s\n", err);
    }
    return code;
}

int main(int argc, char **argv) {
    if (argc >= 4 && std::strcmp(argv[1], "--run") == 0) {
        return runHeadless(argc, argv);
    }
    QApplication app(argc, argv);
    MainWindow window;
    window.show();
    return app.exec();
}
