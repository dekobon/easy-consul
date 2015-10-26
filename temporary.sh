#!/usr/bin/env bash

##
# Platform independent implementation of mktemp.
# Parameter 1: is the desired prefix

# If we aren't using GNU style mktemp, then try to do it the OS X way...
if [ -n "$(mktemp --version 2> /dev/null | head -n1 | grep GNU)" ]; then
    MKTEMP_VER="GNU"
elif [ -n "$(mktemp -t prefix)" ]; then
    MKTEMP_VER="BSD"
else
    MKTEMP_VER="OTHER"
fi

if [ -n "$1" ]; then
    PREFIX="$1"
else
    PREFIX="temporary"
fi

if [ "$MKTEMP_VER" == "GNU" ]; then
    echo "$(mktemp)"
elif [ "$MKTEMP_VER" == "BSD" ]; then
    echo "$(mktemp -t ${PREFIX})"
else
    echo "$(mktemp /tmp/${PREFIX}-XXXXXXXXXX.tmp)"
fi
