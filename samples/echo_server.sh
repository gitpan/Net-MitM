#!/bin/sh

# ####
# vars
# ####

# set this to the directory(ies) into which you have installed the script

dir=~/bin/mitm/samples
libdir=~/bin/mitm/lib

export PERL5LIB="$PERL5LIB:$libdir"

# set the host to listen on

port=8080

# ####
# main
# ####

$dir/echo_server.pl $port

