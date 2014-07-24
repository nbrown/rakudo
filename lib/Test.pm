module Test;
# Copyright (C) 2007 - 2011 The Perl Foundation.

## This is a temporary Test.pm to get us started until we get pugs's Test.pm
## working. It's shamelessly stolen & adapted from MiniPerl6 in the pugs repo.

# settable from outside
my $perl6_test_times = ? %*ENV<PERL6_TEST_TIMES>;

# global state
my @vars;
my $indents = "";

# variables to keep track of our tests
my $num_of_tests_run;
my $num_of_tests_failed;
my $todo_upto_test_num;
my $todo_reason;
my $num_of_tests_planned;
my $no_plan;
my $die_on_fail;
my $time_before;
my $time_after;

# handles
my $output         = $*OUT;
my $failure_output = $*ERR;
my $todo_output    = $*OUT;

try {
    # XXX do this with dup or an analogous cross-platform construct
    my $output_h         = open('/dev/stdout', :w);
    my $failure_output_h = open('/dev/stderr', :w);
    my $todo_output_h    = open('/dev/stdout', :w);

    ( $output, $failure_output, $todo_output ) = ( $output_h, $failure_output_h, $todo_output_h );

    CATCH {}
}

## If done_testing hasn't been run when we hit our END block, we need to know
## so that it can be run. This allows compatibility with old tests that use
## plans and don't call done_testing.
my $done_testing_has_been_run = 0;

# make sure we have initializations
_init_vars();

## test functions

# you can call die_on_fail; to turn it on and die_on_fail(0) to turn it off
sub die_on_fail($fail=1) {
    $die_on_fail = $fail;
}

# "plan 'no_plan';" is now "plan *;"
# It is also the default if nobody calls plan at all
multi sub plan($number_of_tests) is export {
    if $number_of_tests ~~ ::Whatever {
        $no_plan = 1;
    }
    else {
        $num_of_tests_planned = $number_of_tests;
        $no_plan = 0;

        $output.print: $indents;
        $output.say: '1..' ~ $number_of_tests;
    }
    # Get two successive timestamps to say how long it takes to read the
    # clock, and to let the first test timing work just like the rest.
    # These readings should be made with the expression now.to-posix[0],
    # but its execution time when tried in the following two lines is a
    # lot slower than the non portable nqp::p6box_n(nqp::time_n).
    $time_before = nqp::p6box_n(nqp::time_n);
    $time_after  = nqp::p6box_n(nqp::time_n);
    $output.print: $indents
      ~ '# between two timestamps '
      ~ ceiling(($time_after-$time_before)*1_000_000) ~ ' microseconds'
      ~ "\n"
        if $perl6_test_times;
    # Take one more reading to serve as the begin time of the first test
    $time_before = nqp::p6box_n(nqp::time_n);
}

multi sub pass($desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    proclaim(1, $desc);
    $time_before = nqp::p6box_n(nqp::time_n);
}

multi sub ok(Mu $cond, $desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ok = proclaim(?$cond, $desc);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub nok(Mu $cond, $desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ok = proclaim(!$cond, $desc);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub is(Mu $got, Mu $expected, $desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    $got.defined; # Hack to deal with Failures
    my $test = $got eq $expected;
    my $ok = proclaim(?$test, $desc);
    if !$test {
        diag "     got: '$got'";
        diag "expected: '$expected'";
    }
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub isnt(Mu $got, Mu $expected, $desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $test = !($got eq $expected);
    my $ok = proclaim($test, $desc);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub is_approx(Mu $got, Mu $expected, $desc = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $tol = $expected.abs < 1e-6 ?? 1e-5 !! $expected.abs * 1e-6;
    my $test = ($got - $expected).abs <= $tol;
    my $ok = proclaim(?$test, $desc);
    unless $test {
        diag("got:      $got");
        diag("expected: $expected");
    }
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub todo($reason, $count = 1) is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    $todo_upto_test_num = $num_of_tests_run + $count;
    $todo_reason = '# TODO ' ~ $reason;
    $time_before = nqp::p6box_n(nqp::time_n);
}

multi sub skip() {
    $time_after = nqp::p6box_n(nqp::time_n);
    proclaim(1, "# SKIP");
    $time_before = nqp::p6box_n(nqp::time_n);
}
multi sub skip($reason, $count = 1) is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    die "skip() was passed a non-numeric number of tests.  Did you get the arguments backwards?" if $count !~~ Numeric;
    my $i = 1;
    while $i <= $count { proclaim(1, "# SKIP " ~ $reason); $i = $i + 1; }
    $time_before = nqp::p6box_n(nqp::time_n);
}

sub skip_rest($reason = '<unknown>') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    skip($reason, $num_of_tests_planned - $num_of_tests_run);
    $time_before = nqp::p6box_n(nqp::time_n);
}

sub subtest(&subtests, $desc = '') is export {
    _push_vars();
    _init_vars();
    $indents ~= "    ";
    subtests();
    done() if !$done_testing_has_been_run;
    my $status =
      $num_of_tests_failed == 0 && $num_of_tests_planned == $num_of_tests_run;
    _pop_vars;
    $indents = $indents.chop(4);
    proclaim($status,$desc);
}

sub diag(Mu $message) is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    $failure_output.print: $indents;
    my $str-message = $message.Str.subst(rx/^^/, '# ', :g);
    $str-message .= subst(rx/^^'#' \s+ $$/, '', :g);
    $*ERR.say: $str-message;
    $time_before = nqp::p6box_n(nqp::time_n);
}

multi sub flunk($reason) is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ok = proclaim(0, $reason);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub isa_ok(Mu $var, Mu $type, $msg = ("The object is-a '" ~ $type.perl ~ "'")) is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ok = proclaim($var.isa($type), $msg)
        or diag('Actual type: ' ~ $var.^name);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub dies_ok(Callable $closure, $reason = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $death = 1;
    my $bad_death = 0;
    try {
        $closure();
        $death = 0;
    }
    if $death && $!.Str.index('Null PMC access') {
        $bad_death = 1;
        diag("Wrong way to die: '$!'");
    }
    my $ok = proclaim( $death && !$bad_death, $reason );
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub lives_ok(Callable $closure, $reason = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    try {
        $closure();
    }
    my $ok = proclaim((not defined $!), $reason) or diag($!);
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub eval_dies_ok(Str $code, $reason = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ee = eval_exception($code);
    my $ok;
    if defined $ee {
        # XXX no regexes yet in nom
        my $bad_death = $ee.Str.index('Null PMC access ').defined;
        if $bad_death {
            diag "wrong way to die: '$ee'";
        }
        $ok = proclaim( !$bad_death, $reason );
    }
    else {
        $ok = proclaim( 0, $reason );
    }
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub eval_lives_ok(Str $code, $reason = '') is export {
    $time_after = nqp::p6box_n(nqp::time_n);
    my $ee = eval_exception($code);
    my $ok = proclaim((not defined $ee), $reason)
        or diag("Error: $ee");
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

multi sub is_deeply(Mu $got, Mu $expected, $reason = '') is export
{
    $time_after = nqp::p6box_n(nqp::time_n);
    my $test = _is_deeply( $got, $expected );
    my $ok = proclaim($test, $reason);
    if !$test {
        my $got_perl      = try { $got.perl };
        my $expected_perl = try { $expected.perl };
        if $got_perl.defined && $expected_perl.defined {
            diag "     got: $got_perl";
            diag "expected: $expected_perl";
        }
    }
    $time_before = nqp::p6box_n(nqp::time_n);
    return $ok;
}

sub throws_like($code, $ex_type, *%matcher) is export {
    subtest {
        plan 2 + %matcher.keys;
        my $msg;
        if $code ~~ Callable {
            $msg = 'code dies';
            $code()
        } else {
            $msg = "'$code' died";
            EVAL $code;
        }
        ok 0, $msg;
        skip 'Code did not die, can not check exception', 1 + %matcher.elems;
        CATCH {
            default {
                ok 1, $msg;
                my $type_ok = $_ ~~ $ex_type;
                ok $type_ok , "right exception type ({$ex_type.^name})";
                if $type_ok {
                    for %matcher.kv -> $k, $v {
                        my $got = $_."$k"();
                        my $ok = $got ~~ $v,;
                        ok $ok, ".$k matches {$v.defined ?? $v !! $v.gist}";
                        unless $ok {
                            diag "Got:      $got";
                            diag "Expected: $v";
                        }
                    }
                } else {
                    diag "Got:      {$_.WHAT.gist}";
                    diag "Expected: {$ex_type.gist}";
                    diag "Exception message: $_.message()";
                    skip 'wrong exception type', %matcher.elems;
                }
            }
        }
    }, "did we throws_like {$ex_type.^name}?";
}

sub _is_deeply(Mu $got, Mu $expected) {
    $got eqv $expected;
}


## 'private' subs

sub eval_exception($code) {
    try {
        EVAL ($code);
    }
    $!;
}

sub proclaim($cond, $desc) {
    # exclude the time spent in proclaim from the test time
    $num_of_tests_run = $num_of_tests_run + 1;

    $output.print: $indents;
    unless $cond {
        $output.print: "not ";
        unless  $num_of_tests_run <= $todo_upto_test_num {
            $num_of_tests_failed = $num_of_tests_failed + 1
        }
    }
    if $todo_reason and $num_of_tests_run <= $todo_upto_test_num {
        # TAP parsers do not like '#' in the description, they'd miss the '# TODO'
        $output.print: "ok ", $num_of_tests_run, " - ", $desc.subst('#', '', :g), $todo_reason;
    }
    else {
        $output.print: "ok ", $num_of_tests_run, " - ", $desc;
    }
    $output.print: "\n";
    $output.print: $indents
      ~ "# t="
      ~ ceiling(($time_after-$time_before)*1_000_000)
      ~ "\n"
        if $perl6_test_times;

    unless $cond {
        my $caller = callframe(3);
        if $desc ne '' {
            diag "\nFailed test '$desc'\nat {$caller.file} line {$caller.line}";
        } else {
            diag "\nFailed test at {$caller.file} line {$caller.line}";
        }
    }

    if !$cond && $die_on_fail && !$todo_reason {
        die "Test failed.  Stopping test";
    }
    # must clear this between tests
    if $todo_upto_test_num == $num_of_tests_run { $todo_reason = '' }
    $cond;
}

sub done_testing() is export {
    die "done_testing() has been renamed to done(), please change your test code";
}

sub done() is export {
    $done_testing_has_been_run = 1;

    if $no_plan {
        $num_of_tests_planned = $num_of_tests_run;
        $output.print: $indents;
        $output.say: "1..$num_of_tests_planned";
    }

    if ($num_of_tests_planned != $num_of_tests_run) {  ##Wrong quantity of tests
        diag("Looks like you planned $num_of_tests_planned tests, but ran $num_of_tests_run");
    }
    if ($num_of_tests_failed) {
        diag("Looks like you failed $num_of_tests_failed tests of $num_of_tests_run");
    }
}

sub _init_vars {
    $num_of_tests_run     = 0;
    $num_of_tests_failed  = 0;
    $todo_upto_test_num   = 0;
    $todo_reason          = '';
    $num_of_tests_planned = Any;
    $no_plan              = 1;
    $die_on_fail          = Any;
    $time_before          = Any;
    $time_after           = Any;
    $done_testing_has_been_run = 0;
}

sub _push_vars {
    @vars.push: [
      $num_of_tests_run,
      $num_of_tests_failed,
      $todo_upto_test_num,
      $todo_reason,
      $num_of_tests_planned,
      $no_plan,
      $die_on_fail,
      $time_before,
      $time_after,
      $done_testing_has_been_run,
    ];
}

sub _pop_vars {
    (
      $num_of_tests_run,
      $num_of_tests_failed,
      $todo_upto_test_num,
      $todo_reason,
      $num_of_tests_planned,
      $no_plan,
      $die_on_fail,
      $time_before,
      $time_after,
      $done_testing_has_been_run,
    ) = @(@vars.pop);
}

END {
    ## In planned mode, people don't necessarily expect to have to call done
    ## So call it for them if they didn't
    if !$done_testing_has_been_run && !$no_plan {
        done;
    }
    exit($num_of_tests_failed);
}

=begin pod

=head1 NAME

Test - Rakudo Testing Library

=head1 SYNOPSIS

  use Test;

=head1 DESCRIPTION

=head1 FUNCTIONS

=head2 throws_like($code, Mu $expected_type, *%matchers)

If C<$code> is C<Callable>, calls it, otherwise C<EVAL>s it,
and expects it thrown an exception.

If an exception is thrown, it is compared to C<$expected_type>.

Then for each key in C<%matchers>, a method of that name is called
on the resulting exception, and its return value smart-matched against
the value.

Each step is counted as a separate test; if one of the first two fails,
the rest of the tests are skipped.

=end pod

# vim: ft=perl6
