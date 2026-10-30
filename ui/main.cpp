// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include <QApplication>
#include <QLabel>
#include <QMainWindow>

#include <cstdio>

#include "p2z.h"

int main(int argc, char **argv) {
    const uint32_t abi = p2z_abi_version();
    if (abi != P2Z_ABI_VERSION) {
        std::fprintf(stderr,
                     "ABI mismatch: core reports %u, header expects %u. Rebuild both.\n",
                     abi, P2Z_ABI_VERSION);
        return 2;
    }

    QApplication app(argc, argv);

    QMainWindow window;
    window.setWindowTitle("ps4-pkg2zar");
    window.setCentralWidget(new QLabel(
        QStringLiteral("ps4-pkg2zar skeleton, core ABI %1").arg(abi)));
    window.resize(640, 400);
    window.show();

    return app.exec();
}
