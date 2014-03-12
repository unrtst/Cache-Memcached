#!/usr/bin/env perl -w

# This test borrowed from Cache::Memcached::Fast
# It tests how the module deals with values that are "Readonly"
# or "Tie::" objects.

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 70;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

use Tie::Scalar;
use Tie::Array;
use Tie::Hash;

tie my $namespace, 'Tie::StdScalar';
tie my $scalar1, 'Tie::StdScalar';
tie my $scalar2, 'Tie::StdScalar';
tie my $scalar3, 'Tie::StdScalar';
tie my $scalar4, 'Tie::StdScalar';
tie my @array, 'Tie::StdArray';
tie my %hash, 'Tie::StdHash';

# build params for new()
@array = ($testaddr);
$namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";
%hash = (
    servers => \@array,
    namespace => $namespace,
);

my $memd = Cache::Memcached->new( \%hash );

isa_ok($memd, 'Cache::Memcached');

ok($memd->set("key1", "val1"));
is($memd->get("key1"), "val1");

$scalar1 = "key2";
ok($memd->set($scalar1, "val2"));
is($memd->get($scalar1), "val2");
is($memd->get("key2"), "val2");

ok($memd->set("key2", "val2b"));
is($memd->get($scalar1), "val2b");
is($memd->get("key2"), "val2b");

use utf8;
my $key2 = "2Кириллица.в.UTF-8";
$scalar2 = $key2;

# utf8 keys work ok
ok($memd->set($key2,      "val2b"),   "set utf8 key to normal value");
is($memd->get($scalar2),  "val2b",    "get Tie::Scalar utf8 key is normal value");
is($memd->get($key2),     "val2b",    "get utf8 key is normal value");
ok($memd->delete($key2),              "delete utf8 key");

my $key3 = "3Кириллица.в.UTF-8";
$scalar3 = $key3;

ok($memd->set($scalar3,  "val2"),   "set Tie::Scalar utf8 key to normal value");
is($memd->get($scalar3), "val2",    "get Tie::Scalar utf8 key is normal value");
is($memd->get($key3),    "val2",    "get utf8 key is normal value");
ok($memd->delete($scalar3),         "delete Tie::Scalar utf8 key");


TODO: {
    local $TODO = "utf8 values do not appear to work at this time";

    # these cause fatal failures, so we need to wrap them in eval's
    # failures look like this:
    #   Wide character in send at lib/Cache/Memcached.pm line 596.

    my $key4 = "4Кириллица.в.UTF-8";
    $scalar4 = $key4;

    ok(eval{$memd->set("key3", $key4)},      "set key3 to utf8 value");
    ok(eval{$memd->set("key3", $scalar4)},   "set key3 to Tie::StdScalar utf8 value");

    ok(eval{$memd->set($scalar4, $scalar4)},  "set Tie::StdScalar utf8 value to Tie::StdScalar utf8 value");
    my $multi;
    ok($multi = eval{$memd->get_multi($scalar4)}, "get_multi on Tie::Scalar utf8 key");
    ok(exists $multi->{$scalar4},               "get_multi returned Tie::Scalar utf8 key");
    ok(exists $multi->{$key4},                  "get_multi returned utf8 key");
    is(eval{$memd->get($scalar4)}, $key4,       "get Tie::Scalar utf8 key matches utf8 value");
    is(eval{$memd->get($key4)}, $scalar4,       "get utf8 key matches Tie::Scalar utf8 value");
}


package MyScalar;
use base 'Tie::StdScalar';

sub FETCH {
    "item5"
}
#    "Другой.ключ"

package main;

tie my $scalar5, 'MyScalar';

#TODO: {
#    local $TODO = "Tie::Scalar values don't seem to work at this time";

    # these cause fatal failures, so we need to wrap them in eval's
    # failures look like this:
    #   Wide character in send at lib/Cache/Memcached.pm line 596.

    ok($memd->set($scalar5, $scalar5), "set MyScalar item5 to MyScalar item5");
    ok(exists $memd->get_multi($scalar5)->{$scalar5}, "get_multi MyScalar item5 includes it in result");
    is($memd->get_multi($scalar5)->{"item5"}, "item5", "get_multi MyScalar item5 is item5");
    is($memd->get($scalar5), "item5", "get MyScalar is item5");
    is($memd->get("item5"), "item5",  "get item5 is item5");
#}

SKIP: {
    eval { require Readonly };
    skip "Skipping Readonly tests because the module is not present", 40
      if $@;

    # XXX: SPECIAL NOTES REGARDING THIS SECTION:

    # 'require Readonly' as above can be used to test if the module is
    # present, but won't actually work.  So below we 'use Readonly',
    # but in a string eval.

    # Put only one test set per eval so that one fatal failure doesn't ruin them all.
    # (allows one to figure out what triggered the failure)

    # Readonly syntax is different depending on perl version, so we setup two blocks.
    # This was done just like Readonly.pm's t/readonly.t

  SKIP:
  {
    skip 'Readonly \\ syntax is for perls earlier than 5.8', 20 if $] >= 5.008;

    # Readonly expires
    eval q{
        use Readonly;

        Readonly \my $expires => 3;
        ok($memd->set("key6", "val6", $expires), "set key6 to scalar val6 with Readonly expires");
        is($memd->get("key6"), "val6",           "get key6 is scalar val6");
        is($memd->get_multi("key6")->{"key6"}, "val6", "get_multi key6");
        sleep(4);
        ok(! $memd->get("key6"),                 "get key6 expired at correct time");
    };
    if ($@) {
        fail("Readonly expires tests: $@");
        fail("Readonly expires tests");
        fail("Readonly expires tests");
        fail("Readonly expires tests");
    }
    # Readonly ascii key
    eval q{
        use Readonly;

        Readonly \my $key7 => "key7";
        ok($memd->set($key7, "val7"), "set Readonly key6 to scalar val7");
        is($memd->get($key7), "val7", "get Readonly key6 is scalar val7");
        is($memd->get_multi($key7)->{$key7}, "val7", "get_multi key7");
    };
    if ($@) {
        fail("Readonly ascii key tests: $@");
        fail("Readonly ascii key tests");
        fail("Readonly ascii key tests");
    }
    # Readonly ascii value
    eval q{
        use Readonly;

        Readonly \my $val8 => "val8";
        ok($memd->set("key8", $val8), "set scalar key8 to Readonly val8");
        is($memd->get("key8"), $val8, "get scalar key8 is Readonly val8");
        is($memd->get_multi("key8")->{"key8"}, $val8, "get_multi key8");
    };
    if ($@) {
        fail("Readonly ascii value tests: $@");
        fail("Readonly ascii value tests");
        fail("Readonly ascii value tests");
    }
    # Readonly utf8 key
    eval q{
        use Readonly;

        Readonly \my $key9 => "9Третий.ключ";
        ok($memd->set($key9, "val9"), "set Readonly utf8 key9 to scalar val9");
        is($memd->get($key9), "val9", "get Readonly utf8 key9 is scalar val9");
        is($memd->get_multi($key9)->{$key9}, "val9", "get_multi key9");
    };
    if ($@) {
        fail("Readonly utf8 key tests: $@");
        fail("Readonly utf8 key tests");
        fail("Readonly utf8 key tests");
    }
    TODO: {
        # nesting a normal TODO under the skip didn't behave well.
        # using todo_skip instead
        # local $TODO = "utf8 values do not appear to work at this time";
        todo_skip "utf8 values do not appear to work at this time", 7;

        # Readonly utf8 value
        eval q{
            use Readonly;

            Readonly \my $val10 => "10Третий.ключ";
            ok($memd->set("key10", $val10), "set scalar key10 to Readonly utf8 value");
            is($memd->get("key10"), $val10, "get scalar key10 is Readonly utf8 value");
            is($memd->get_multi("key10")->{"key10"}, $val10, "get_multi key10");
        };
        if ($@) {
            fail("Readonly utf8 value tests: $@");
            fail("Readonly utf8 value tests");
            fail("Readonly utf8 value tests");
        }
        # Readonly expires, utf8 key, and utf8 value
        eval q{
            use Readonly;

            Readonly \my $expires => 3;
            Readonly \my $key11 => "11Третий.ключ";
            Readonly \my $val11 => "11Третий.ключ";
            ok($memd->set($key11, $val11, $expires), "set Readonly utf8 key to Readonly utf8 value with Readonly expires");
            is($memd->get($key11), $val11,           "get Readonly utf8 key is Readonly utf8 value");
            is($memd->get_multi($key11)->{$key11}, $val11, "get_multi key 11");
            sleep(4);
            ok(! $memd->get($key11),                 "get Readonly utf8 key expired at correct time");
        };
        if ($@) {
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests: $@");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
        }
    }
  }

  SKIP:
  {
    skip 'Readonly $@% syntax is for perl 5.8 or later', 20 unless $] >= 5.008;

    # Readonly expires
    eval q{
        use Readonly;

        Readonly my $expires => 3;
        ok($memd->set("key6", "val6", $expires), "set key6 to scalar val6 with Readonly expires");
        is($memd->get("key6"), "val6",           "get key6 is scalar val6");
        is($memd->get_multi("key6")->{"key6"}, "val6", "get_multi key6");
        sleep(4);
        ok(! $memd->get("key6"),                 "get key6 expired at correct time");
    };
    if ($@) {
        fail("Readonly expires tests: $@");
        fail("Readonly expires tests");
        fail("Readonly expires tests");
        fail("Readonly expires tests");
    }
    # Readonly ascii key
    eval q{
        use Readonly;

        Readonly my $key7 => "key7";
        ok($memd->set($key7, "val7"), "set Readonly key6 to scalar val7");
        is($memd->get($key7), "val7", "get Readonly key6 is scalar val7");
        is($memd->get_multi($key7)->{$key7}, "val7", "get_multi key7");
    };
    if ($@) {
        fail("Readonly ascii key tests: $@");
        fail("Readonly ascii key tests");
        fail("Readonly ascii key tests");
    }
    # Readonly ascii value
    eval q{
        use Readonly;

        Readonly my $val8 => "val8";
        ok($memd->set("key8", $val8), "set scalar key8 to Readonly val8");
        is($memd->get("key8"), $val8, "get scalar key8 is Readonly val8");
        is($memd->get_multi("key8")->{"key8"}, $val8, "get_multi key8");
    };
    if ($@) {
        fail("Readonly ascii value tests: $@");
        fail("Readonly ascii value tests");
        fail("Readonly ascii value tests");
    }
    # Readonly utf8 key
    eval q{
        use Readonly;

        Readonly my $key9 => "9Третий.ключ";
        ok($memd->set($key9, "val9"), "set Readonly utf8 key9 to scalar val9");
        is($memd->get($key9), "val9", "get Readonly utf8 key9 is scalar val9");
        is($memd->get_multi($key9)->{$key9}, "val9", "get_multi key9");
    };
    if ($@) {
        fail("Readonly utf8 key tests: $@");
        fail("Readonly utf8 key tests");
        fail("Readonly utf8 key tests");
    }

    TODO: {
        # nesting a normal TODO under the skip didn't behave well.
        # using todo_skip instead
        # local $TODO = "utf8 values do not appear to work at this time";
        todo_skip "utf8 values do not appear to work at this time", 7;

        # Readonly utf8 value
        eval q{
            use Readonly;

            Readonly my $val10 => "10Третий.ключ";
            ok($memd->set("key10", $val10), "set scalar key10 to Readonly utf8 value");
            is($memd->get("key10"), $val10, "get scalar key10 is Readonly utf8 value");
            is($memd->get_multi("key10")->{"key10"}, $val10, "get_multi key10");
        };
        if ($@) {
            fail("Readonly utf8 value tests: $@");
            fail("Readonly utf8 value tests");
            fail("Readonly utf8 value tests");
        }
        # Readonly expires, utf8 key, and utf8 value
        eval q{
            use Readonly;

            Readonly my $expires => 3;
            Readonly my $key11 => "11Третий.ключ";
            Readonly my $val11 => "11Третий.ключ";
            ok($memd->set($key11, $val11, $expires), "set Readonly utf8 key to Readonly utf8 value with Readonly expires");
            is($memd->get($key11), $val11,           "get Readonly utf8 key is Readonly utf8 value");
            is($memd->get_multi($key11)->{$key11}, $val11, "get_multi key 11");
            sleep(4);
            ok(! $memd->get($key11),                 "get Readonly utf8 key expired at correct time");
        };
        if ($@) {
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests: $@");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
            fail("combined Readonly expires, Readonly utf8 key, Readonly utf8 value tests");
        }
    }
  }
}


