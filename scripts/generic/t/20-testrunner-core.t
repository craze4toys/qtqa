#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;

=head1 NAME

20-testrunner-core.t - test testrunner's coredump handling

=head1 SYNOPSIS

  perl ./20-testrunner-core.t

This test will run the testrunner.pl script with some crashing processes
and do a basic verification that a backtrace of some kind was captured.

=cut

use Capture::Tiny qw( capture );
use English qw( -no_match_vars );
use File::Basename;
use File::Slurp qw( read_file );
use File::Temp qw( tempdir );
use FindBin;
use Readonly;
use Test::More;

use lib "$FindBin::Bin/../../lib/perl5";
use QtQA::Test::More qw( is_or_like );

# Matches backtrace text expected when a segfault occurs
Readonly my $SIGSEGV_BACKTRACE => qr{

    \A

    # We can't feasibly code the expected backtrace, so we just test that...
    #  (1) the core plugin claims to be producing a backtrace (backtrace follows:)
    QtQA::App::TestRunner: [^\n]+ backtrace[ ]follows:[^\n]+    \n

    .*

    #  (2) a "Program terminated with" message is printed with gdb-compatible format
    \QQtQA::App::TestRunner: Program terminated with signal 11\E

    .*

    \z

}xms;

# Testdata for core_pattern_to_glob_pattern
Readonly my @CORE_TO_GLOB_TESTDATA => (
    # trivial and default
    {
        core_pattern  => 'core',
        core_uses_pid => 0,
        glob_pattern  => 'core',
    },

    # pid on the end
    {
        core_pattern  => 'core',
        core_uses_pid => 1,
        glob_pattern  => 'core.*',
    },

    # pid on the end via %p
    {
        core_pattern  => 'core-%p',
        core_uses_pid => 0,
        glob_pattern  => 'core-*',
    },

    # literal %
    {
        core_pattern  => '/tmp/core%%foo/%e/bar',
        core_uses_pid => 0,
        glob_pattern  => '/tmp/core%foo/*',
    },

    # core_uses_pid makes no difference past the variable portion
    {
        core_pattern  => 'my-core-file:%t',
        core_uses_pid => 1,
        glob_pattern  => 'my-core-file:*',
    },

    # "piping core" behaves like `core'
    {
        core_pattern  => '|/usr/bin/some-cool-handler',
        core_uses_pid => 0,
        glob_pattern  => 'core',
    },

    # "piping core" with pid behaves like `core.%p'
    {
        core_pattern  => '|/usr/bin/some-cool-handler',
        core_uses_pid => 1,
        glob_pattern  => 'core.*',
    },
);

sub test_run
{
    my ($params_ref) = @_;

    my @args              = @{$params_ref->{ args }};
    my $expected_stdout   =   $params_ref->{ expected_stdout };
    my $expected_stderr   =   $params_ref->{ expected_stderr };
    my $expected_success  =   $params_ref->{ expected_success };
    my $expected_logfile  =   $params_ref->{ expected_logfile };
    my $expected_logtext  =   $params_ref->{ expected_logtext }  // "";
    my $testname          =   $params_ref->{ testname }          // q{};

    my $status;
    my ($output, $error) = capture {
        $status = system( 'perl', "$FindBin::Bin/../testrunner.pl", @args );
    };

    if ($expected_success) {
        is  ( $status, 0, "$testname exits zero" );
    }
    else {
        isnt( $status, 0, "$testname exits non-zero" );
    }

    is_or_like( $output, $expected_stdout, "$testname output looks correct" );
    is_or_like( $error,  $expected_stderr, "$testname error looks correct" );

    # The rest of the verification steps are only applicable if a log file is expected and created
    return if (!$expected_logfile);
    return if (!ok( -e $expected_logfile, "$testname created $expected_logfile" ));

    my $logtext = read_file( $expected_logfile );   # dies on error
    is_or_like( $logtext, $expected_logtext, "$testname logtext is as expected" );

    return;
}

sub test_testrunner
{
    # control; check that `--plugin core' can load OK
    test_run({
        testname         => 'plugin loads OK 0 exitcode',
        args             => [ '--plugin', 'core', '--', 'true' ],
        expected_success => 1,
        expected_stdout  => q{},
        expected_stderr  => q{},
    });

    # another control; check that it doesn't break non-zero exit code
    test_run({
        testname         => 'plugin loads OK !0 exitcode',
        args             => [ '--plugin', 'core', '--', 'false' ],
        expected_success => 0,
        expected_stdout  => q{},
        expected_stderr  => q{},
    });

    # check that a backtrace is generated if process crashes
    test_run({
        testname         => 'simple backtrace',
        args             => [ '--plugin', 'core', '--', 'perl', '-e', 'kill 11, $$' ],
        expected_success => 0,
        expected_stdout  => q{},
        expected_stderr  => $SIGSEGV_BACKTRACE,
    });


    # check that the backtrace is captured to log OK
    my $tempdir = tempdir( basename($0).'.XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    test_run({
        testname         => 'backtrace to log',
        args             => [
            '--capture-logs',
            $tempdir,
            '--plugin',
            'core',
            '--',
            'perl',
            '-e',
            'kill 11, $$'
        ],
        expected_success => 0,
        expected_stdout  => q{},
        expected_stderr  => q{},
        expected_logfile => "$tempdir/perl-00.txt",
        expected_logtext => $SIGSEGV_BACKTRACE,
    });

    # And again, with --tee
    test_run({
        testname         => 'backtrace to log',
        args             => [
            '--tee-logs',
            $tempdir,
            '--plugin',
            'core',
            '--',
            'perl',
            '-e',
            'kill 11, $$'
        ],
        expected_success => 0,
        expected_stdout  => q{},
        expected_stderr  => $SIGSEGV_BACKTRACE,
        expected_logfile => "$tempdir/perl-01.txt",
        expected_logtext => $SIGSEGV_BACKTRACE,
    });

    return;
}

sub test_core_pattern_to_glob_pattern
{
    ok( do("$FindBin::Bin/../testrunner-plugins/core.pm"), "plugin loaded OK" );

    my $plugin = QtQA::App::TestRunner::Plugin::core->new( );

    foreach my $row (@CORE_TO_GLOB_TESTDATA) {
        my $testname = "$row->{ core_pattern }, core_uses_pid $row->{ core_uses_pid }";

        my $expected_glob_pattern = $row->{ glob_pattern };
        my $actual_glob_pattern   = $plugin->_core_pattern_to_glob_pattern(
            $row->{ core_pattern },
            $row->{ core_uses_pid },
        );

        is( $actual_glob_pattern, $expected_glob_pattern, "glob pattern for $testname" );
    }

    return;
}

sub run
{
    if ($OSNAME !~ m{linux}i) {
        plan 'skip_all', "test is not relevant on $OSNAME";
    }

    test_core_pattern_to_glob_pattern;
    test_testrunner;
    done_testing;

    return;
}

run if (!caller);
1;

