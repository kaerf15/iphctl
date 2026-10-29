#!/usr/bin/env python3
"""Launch the iphctl agent control app."""

import os
import sys

binary = os.path.join(os.path.dirname(os.path.abspath(__file__)), "iphctl")
os.execv(binary, [binary, *sys.argv[1:]])
