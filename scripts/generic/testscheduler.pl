#!/usr/bin/env perl
#############################################################################
##
## Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
## Contact: http://www.qt-project.org/
##
## This file is part of the Quality Assurance module of the Qt Toolkit.
##
## $QT_BEGIN_LICENSE:LGPL$
## GNU Lesser General Public License Usage
## This file may be used under the terms of the GNU Lesser General Public
## License version 2.1 as published by the Free Software Foundation and
## appearing in the file LICENSE.LGPL included in the packaging of this
## file. Please review the following information to ensure the GNU Lesser
## General Public License version 2.1 requirements will be met:
## http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
##
## In addition, as a special exception, Nokia gives you certain additional
## rights. These rights are described in the Nokia Qt LGPL Exception
## version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
##
## GNU General Public License Usage
## Alternatively, this file may be used under the terms of the GNU General
## Public License version 3.0 as published by the Free Software Foundation
## and appearing in the file LICENSE.GPL included in the packaging of this
## file. Please review the following information to ensure the GNU General
## Public License version 3.0 requirements will be met:
## http://www.gnu.org/copyleft/gpl.html.
##
## Other Usage
## Alternatively, this file may be used in accordance with the terms and
## conditions contained in a signed written agreement between you and Nokia.
##
##
##
##
##
##
## $QT_END_LICENSE$
##
#############################################################################

use 5.010;
use strict;
use warnings;

package QtQA::App::TestScheduler;

=head1 NAME

testscheduler - run a set of autotests

=head1 SYNOPSIS

  # Run all tests mentioned in testplan.txt, up to 4 at a time
  $ ./testscheduler --plan testplan.txt -j4 --timeout 120

Run a set of testcases and output a summary of the results.

=head2 OPTIONS

=over

=item --plan FILENAME (Mandatory)

Execute the test plan from this file.
The test plan should be generated by the "testplanner" command.

=item -j N

=item --jobs N

Execute tests in parallel, up to N concurrently.

Note that only tests marked with parallel_test in the testplan
are permitted to run in parallel.

=item --no-summary

=item --summary

Disable/enable printing a summary of test timing, failures, and
totals at the end of the test run.  Enabled by default.

=item --debug

Output a lot of additional information.  Use it for debugging,
when something goes wrong.

=back

All other arguments are passed to the "testrunner" script,
which is invoked once for each test.

=head1 DESCRIPTION

testscheduler runs a set of autotests from a testplan.

testscheduler implements appropriate handling of insignificant
tests and parallel tests according to the metadata in the
testplan (which generally comes from the build system):

=over

=item *

Tests may be run in parallel if they are marked with
parallel_test and testscheduler is invoked with a -j option
higher than 1.

=item *

Test failures may be ignored if a test is marked with insignificant_test.

=back

=cut

use feature 'switch';

use English qw(-no_match_vars);
use Data::Dumper;
use File::Spec::Functions;
use FindBin;
use IO::File;
use Lingua::EN::Inflect qw(inflect);
use List::MoreUtils qw(before after_incl any);
use List::Util qw(sum);
use Pod::Usage;
use Readonly;
use Timer::Simple;

use Getopt::Long qw(
    GetOptionsFromArray
    :config pass_through bundling
);

# testrunner script
Readonly my $TESTRUNNER => catfile( $FindBin::Bin, 'testrunner.pl' );

# declarations of static functions
sub timestr;

sub new
{
    my ($class) = @_;

    return bless {
        jobs => 1,
        debug => 0,
        summary => 1,
    }, $class;
}

sub run
{
    my ($self, @args) = @_;

    GetOptionsFromArray( \@args,
        'help|?'    =>  sub { pod2usage(0) },
        'plan=s'    =>  \$self->{ testplan },
        'j|jobs=i'  =>  \$self->{ jobs },
        'debug'     =>  \$self->{ debug },
        'summary!'  =>  \$self->{ summary },
    ) || pod2usage(2);

    # Strip trailing --, if that's what ended our argument processing
    if (@args && $args[0] eq '--') {
        shift @args;
    }

    # All remaining args are for testrunner
    $self->{ testrunner_args } = [ @args ];

    if (!$self->{ testplan }) {
        die "Missing mandatory --plan argument";
    }

    my @results = $self->do_testplan( $self->{ testplan } );

    $self->debug( sub { 'results: '.Dumper(\@results) } );

    if ($self->{ summary }) {
        $self->print_timing( @results );
        $self->print_failures( @results );
        $self->print_totals( @results );
    }

    $self->exit_appropriately( @results );

    return;
}

sub debug
{
    my ($self, $to_print) = @_;

    return unless $self->{ debug };

    my @to_print;
    given (ref($to_print)) {
        when ('CODE')  { @to_print = $to_print->(); }
        when ('ARRAY') { @to_print = @{$to_print}; }
        default        { @to_print = ($to_print); }
    };

    my $message = __PACKAGE__ . ": debug: @to_print";
    if ($message !~ m{\n\z}) {
        $message .= "\n";
    }

    warn $message;

    return;
}

sub do_testplan
{
    my ($self, $testplan) = @_;

    my @tests = $self->read_tests_from_testplan( $testplan );

    $self->debug( sub { 'testplan: '.Dumper(\@tests) } );

    # tests are sorted for predictable execution order.
    @tests = sort { $a->{ label } cmp $b->{ label } } @tests;

    my @out = $self->execute_tests_from_testplan( @tests );

    return @out;
}

sub print_failures
{
    my ($self, @tests) = @_;

    my @failures = grep { $_->{ _status } } @tests;
    @failures or return;

    print <<'EOF';
=== Failures: ==================================================================
EOF
    foreach my $test (@failures) {
        my $out = "  $test->{ label }";
        if ($test->{ insignificant_test }) {
            $out .= " [insignificant]";
        }
        print "$out\n";
    }

    return;
}

sub print_totals
{
    my ($self, @tests) = @_;

    my $total = 0;
    my $pass = 0;
    my $fail = 0;
    my $insignificant_fail = 0;

    foreach my $test (@tests) {
        ++$total;
        if ($test->{ _status } == 0) {
            ++$pass;
        } elsif ($test->{ insignificant_test }) {
            ++$insignificant_fail;
        } else {
            ++$fail;
        }
    }

    my $message = inflect "=== Totals: NO(test,$total), NO(pass,$pass)";
    if ($fail) {
        $message .= inflect ", NO(fail,$fail)";
    }
    if ($insignificant_fail) {
        $message .= inflect ", NO(insignificant fail,$insignificant_fail)";
    }

    $message .= ' ';

    while (length($message) < 80) {
        $message .= '=';
    }

    print "$message\n";

    return;
}

sub print_timing
{
    my ($self, @tests) = @_;

    my $parallel_total = $self->{ parallel_timer }->elapsed;
    my $serial_total = $self->{ serial_timer }->elapsed;
    my $total = $parallel_total + $serial_total;

    # This is the time it would have taken to run the parallel tests
    # if they were not actually run in parallel.
    my $parallel_j1_total = sum( map( {
        ($self->{ jobs } > 1 && $_->{ parallel_test }) ? $_->{ _timer }->elapsed : 0
    } @tests )) || 0;

    # This fudge factor adjusts for the fact that some tests would be able
    # to run faster if they were the only test running.
    # Another way of thinking of this is: by running tests in parallel, we
    # assume we've slowed down individual tests by about 10%.
    if ($self->{ jobs } > 1) {
        $parallel_j1_total *= 0.9;
    }

    # This is the time we estimate we've "wasted" on insignificant tests.
    my $insignificant_total = sum map( {
        if (!$_->{ insignificant_test }) {
            0;
        } elsif ($_->{ _parallel_count}) {
            $_->{ _timer }->elapsed / $_->{ _parallel_count };
        } else {
            $_->{ _timer }->elapsed;
        }
    } @tests );

    my $parallel_speedup = $parallel_j1_total - $parallel_total;

    printf( <<'EOF',
=== Timing: =================== TEST RUN COMPLETED! ============================
  Total:                                       %s
  Serial tests:                                %s
  Parallel tests:                              %s
  Estimated time spent on insignificant tests: %s
  Estimated time saved by -j%d:                 %s
EOF
        timestr( $total ),
        timestr( $serial_total ),
        timestr( $parallel_total ),
        timestr( $insignificant_total ),
        $self->{ jobs },
        timestr( $parallel_speedup ),
    );

    return;
}

sub read_tests_from_testplan
{
    my ($self, $testplan) = @_;

    my @tests;

    my $fh = IO::File->new( $testplan, '<' ) || die "open $testplan for read: $!";
    my $line_no = 0;
    while (my $line = <$fh>) {
        ++$line_no;
        my $test = eval $line;  ## no critic (ProhibitStringyEval)
        if (my $error = $@) {
            die "$testplan:$line_no: error: $error";
        }
        push @tests, $test;
    }

    return @tests;
}

sub execute_tests_from_testplan
{
    my ($self, @tests) = @_;

    my $jobs = $self->{ jobs };

    # Results will be recorded here.
    # Each element is equal to an input element from @tests with additional keys added.
    # Any keys added from testscheduler start with an '_' so they won't clash with
    # keys from the testplan.
    #
    # Result keys include:
    #   _status         =>  exit status of test
    #   _parallel_count =>  amount of tests still running at the time this test completed
    #   _timer          =>  Timer::Simple object for this test's runtime
    #
    $self->{ test_results } = [];

    # Do all the parallel tests first, then serial.
    # However, if jobs are 1, all tests are serial.
    my @parallel_tests;
    my @serial_tests;
    foreach my $test (@tests) {
        if ($test->{ parallel_test } && $jobs > 1) {
            push @parallel_tests, $test;
        }
        else {
            push @serial_tests, $test;
        }
    }

    # If there is only one parallel test, downgrade it to a serial test
    if (@parallel_tests == 1) {
        @serial_tests = (@parallel_tests, @serial_tests);
        @parallel_tests = ();
    }

    local $SIG{ INT } = sub {
        die 'aborting due to SIGINT';
    };

    $self->{ parallel_timer } = Timer::Simple->new( );
    $self->execute_parallel_tests( @parallel_tests );
    $self->{ parallel_timer }->stop( );

    if (@parallel_tests && @serial_tests) {
        my $p = scalar( @parallel_tests );
        my $s = scalar( @serial_tests );
        # NO -> Number Of
        $self->print_info( inflect "ran NO(parallel test,$p).  Starting NO(serial test,$s).\n" );
    }

    $self->{ serial_timer } = Timer::Simple->new( );
    $self->execute_serial_tests( @serial_tests );
    $self->{ serial_timer }->stop( );

    my @test_results = @{ $self->{ test_results } };

    # Sanity check
    if (scalar(@test_results) != scalar(@tests)) {
        die 'internal error: I expected to run '.scalar(@tests).' tests, but only '
           .scalar(@test_results).' tests reported results';
    }

    return @test_results;
}

sub execute_parallel_tests
{
    my ($self, @tests) = @_;
    return unless @tests;

    while (my $test = shift @tests) {
        while ($self->running_tests_count() >= $self->{ jobs }) {
            $self->wait_for_test_to_complete( );
        }
        $self->spawn_subtest(
            test => $test,
            testrunner_args => [ '--sync-output' ],
        );
    }

    while ($self->running_tests_count()) {
        $self->wait_for_test_to_complete( );
    }

    return;
}

sub execute_serial_tests
{
    my ($self, @tests) = @_;

    return unless @tests;

    while (my $test = shift @tests) {
        while ($self->running_tests_count()) {
            $self->wait_for_test_to_complete( );
        }
        $self->spawn_subtest( test => $test );
    }

    while ($self->running_tests_count()) {
        $self->wait_for_test_to_complete( );
    }

    return;
}

sub print_info
{
    my ($self, $info) = @_;

    local $| = 1;
    print __PACKAGE__.': '.$info;

    return;
}

sub spawn_subtest
{
    my ($self, %args) = @_;

    my $test = $args{ test };

    my @testrunner_args = (
        '--chdir',
        $test->{ cwd },
        @{ $args{ testrunner_args } || []},
        @{ $self->{ testrunner_args } || []},
    );

    my @cmd_and_args = @{ $test->{ args } };

    my @testrunner_cmd = (
        $EXECUTABLE_NAME,
        $TESTRUNNER,
        @testrunner_args,
    );

    my @cmd = (@testrunner_cmd, '--', @cmd_and_args );
    $test->{ _timer } = Timer::Simple->new( );
    my $pid = $self->spawn( @cmd );
    $self->{ test_by_pid }{ $pid } = $test;

    return;
}

sub running_tests_count
{
    my ($self) = @_;

    my $out = scalar keys %{ $self->{ test_by_pid } || {} };

    $self->debug( "$out test(s) currently running" );

    return $out;
}

# Waits for one test to complete and writes the '_status' key for that test.
sub wait_for_test_to_complete
{
    my ($self, $flags) = @_;

    return if (!$self->running_tests_count( ));

    my $pid = waitpid( -1, $flags || 0 );
    my $status = $?;

    $self->debug( sprintf( "waitpid: (pid: %d, status: %d, exitcode: %d)", $pid, $status, $status >> 8) );

    if ($pid <= 0) {
        # this means no child processes
        return;
    }

    my $test = delete $self->{ test_by_pid }{ $pid };
    if (!$test) {
        warn "waitpid returned $pid; this pid could not be associated with any running test";
        return;
    }

    $test->{ _timer }->stop( );
    $test->{ _status } = $status;
    $test->{ _parallel_count } = $self->running_tests_count( );

    $self->print_test_fail_info( $test );

    push @{ $self->{ test_results } }, $test;

    return;
}

sub print_test_fail_info
{
    my ($self, $test) = @_;

    if ($test->{ _status } == 0) {
        return;
    }

    my $msg = "$test->{ label } failed";
    if ($test->{ insignificant_test }) {
        $msg .= ', but it is marked with insignificant_test';
    }

    $self->print_info( "$msg\n" );

    return;
}

sub spawn
{
    my ($self, @cmd) = @_;

    my $pid;

    if ($OSNAME =~ m{win32}i) {
        # see `perldoc perlport'
        $pid = system( 1, @cmd );
    } else {
        $pid = fork();
        if ($pid == -1) {
            die "fork: $!";
        }
        if ($pid == 0) {
            exec( @cmd );
            die "exec: $!";
        }
    }

    $self->debug( sub { "spawned $pid <- ".join(' ', map { "[$_]" } @cmd) } );

    return $pid;
}

sub exit_appropriately
{
    my ($self, @tests) = @_;

    my $fail = any { $_->{ _status } && !$_->{ insignificant_test } } @tests;

    exit( $fail ? 1 : 0 );
}

#======= static functions =========================================================================

# Given an interval of time in seconds, returns a human-readable string
# using the units a reader would most likely prefer to see;
# e.g.
#
#    timestr(12345) -> '3 hours 25 minutes'
#    timestr(123)   -> '2 minutes 3 seconds'
#
sub timestr
{
    my ($seconds) = @_;

    if (!$seconds) {
        return '(no time)';
    }

    $seconds = int($seconds);

    if (!$seconds) {
        # Not zero before truncation to int,
        # but now it is zero; then, an almost-zero time
        return '< 1 second';
    }

    my $hours;
    my $minutes;

    if ($seconds > 60*60) {
        $hours = int($seconds/60/60);
        $seconds -= $hours*60*60;

        $minutes = int($seconds/60);
        $seconds = 0;
    } elsif ($seconds > 60) {
        $minutes = int($seconds/60);
        $seconds -= $minutes*60;
    }

    my @out;
    if ($hours) {
        push @out, inflect( "NO(hour,$hours)" );
    }
    if ($minutes) {
        push @out, inflect( "NO(minute,$minutes)" );
    }
    if ($seconds) {
        push @out, inflect( "NO(second,$seconds)" );
    }

    return "@out";
}

#==================================================================================================

QtQA::App::TestScheduler->new( )->run( @ARGV ) if (!caller);
1;
