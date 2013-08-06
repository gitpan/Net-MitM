#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More tests => 1;

BEGIN {
    use_ok( 'Net::MitM' ) || print "Bail out!\n";
}

diag( "Testing Net::MitM $Net::MitM::VERSION, Perl $], $^X" );
