#!/bin/bash

curl -L https://github.com/Jarred-Sumner/vscode-zig/releases/download/march18/zig-0.2.5.vsix >/home/ubuntu/vscode-zig.vsix
git clone https://github.com/zigtools/zls /home/ubuntu/zls
cd /home/ubuntu/zls
git submodule update --init --recursive --progress --depth=1
zig build -Drelease-fast
