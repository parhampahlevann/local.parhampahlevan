#!/bin/bash

# English Warp Script - Direct connection to original Chinese script
# Only translates the interface, uses all original functionality

echo "=============================================="
echo "  English Warp Script - Cloudflare WARP"
echo "  Connecting to original Chinese script..."
echo "=============================================="
echo ""
echo "This script will run the original CFwarp.sh script"
echo "with English translations for the menu options."
echo ""
echo "IMPORTANT: The actual installation is handled by"
echo "the original script at:"
echo "https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh"
echo ""
echo "Loading English interface..."
sleep 2

# Clear screen and show English instructions
clear
cat << EOF
=================================================
       WARP SCRIPT - ENGLISH INTERFACE
=================================================

What you need to select in the original Chinese menu:

When the original Chinese script starts, you'll see:
__________________________________________________

Option 1: 方案一：安装/切换WARP-GO
          [This means: Option 1: Install/Switch WARP-GO]
          - PRESS: 1

Then you'll see:
Option 1: 安装/切换WARP单栈IPV4（回车默认）
          [This means: Install/Switch WARP IPv4 Single Stack (Enter for default)]
          - PRESS: 1 (or just press Enter)

__________________________________________________

The script will now launch the original Chinese CFwarp.sh
Simply follow the key presses shown above.

[Press Enter to continue to the original script...]
EOF

read -p ""

# Run the original Chinese script with pre-selected options
echo "Connecting to original script..."
bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh)
