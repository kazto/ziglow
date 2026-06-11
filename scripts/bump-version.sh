#!/bin/bash


ROOTDIR=$(cd $(dirname $0)/..; pwd)


VERSION=$(bump $1 -w -f $ROOTDIR/build.zig.zon -p '.version = "(\d+.\d+.\d+)"')
bump $1 -w -f $ROOTDIR/src/main.zig -p '.version = "(\d+.\d+.\d+)"'

git tag v$VERSION
