#!/usr/bin/env bash
# arch-setup: start the installer (stage 1, run from the Arch ISO). Short name for the install command.
exec bash "$(dirname "$0")/stage1/install.sh" "$@"
