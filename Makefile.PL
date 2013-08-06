use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Net::MitM',
    AUTHOR           => q{Ben AVELING <bena.aveling at optusnet.com.au>},
    VERSION_FROM     => 'lib/Net/MitM.pm',
    ABSTRACT_FROM    => 'lib/Net/MitM.pm',
    LICENSE          => 'Artistic_2',
    #LICENSE          => 'perl',
    PL_FILES         => {},
    MIN_PERL_VERSION => 5.006,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        #'ABC'              => 1.6,
        #'Foo::Bar::Module' => 5.0401,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Net-MitM-*' },
);
