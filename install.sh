#!/bin/bash

# Simple English WARP Script

clear
echo "========================================================"
echo "          WARP IPv4 Installation - English Guide"
echo "========================================================"
echo ""
echo "RUNNING ORIGINAL CHINESE SCRIPT..."
echo "Please select these options when prompted:"
echo ""
echo "STEP 1: Select → '方案一：安装/切换WARP-GO'"
echo "        (Option 1: Install/Switch WARP-GO)"
echo "        PRESS: 1"
echo ""
echo "STEP 2: Select → '安装/切换WARP单栈IPV4（回车默认）'"
echo "        (Install/Switch WARP IPv4 Single Stack)"
echo "        PRESS: 1 or just press Enter"
echo ""
echo "========================================================"
echo "Starting the original script now..."
echo "========================================================"
sleep 3

# Run the exact original script
bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh)
