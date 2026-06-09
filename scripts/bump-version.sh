#!/bin/bash


ROOTDIR=$(cd $(dirname $0)/..; pwd)


VERSION=$(bump -w $1 -f $ROOTDIR/build.zig.zon -p '.version = "(\d+.\d+.\d+)"')
bump -w $1 -f $ROOTDIR/src/main.zig  -p '.version = "(\d+.\d+.\d+)"'

git tag v$VERSION
