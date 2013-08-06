@echo off

rem  ####
rem  vars
rem  ####

rem  set this to the directory(ies) into which you have installed the script

set dir=c:\bin\mitm\samples
set libdir=c:\bin\mitm\lib

set PERL5LIB=%PERL5LIB%;%libdir%

rem  set the host to listen on

set port=8080

rem  ####
rem  main
rem  ####

perl %dir%\echo_server.pl %port%

