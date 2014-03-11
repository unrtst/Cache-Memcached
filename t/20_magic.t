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
    plan tests => 27;
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
    "Другой.ключ"
}

package main;

tie my $scalar2, 'MyScalar';

TODO: {
    local $TODO = "Tie::Scalar values don't seem to work at this time";

    # these cause fatal failures, so we need to wrap them in eval's
    # failures look like this:
    #   Wide character in send at lib/Cache/Memcached.pm line 596.

    ok(eval{$memd->set($scalar2, $scalar2)});
    ok(eval{exists $memd->get_multi($scalar2)->{$scalar2}});
}

SKIP: {
    eval { require Readonly };
    skip "Skipping Readonly tests because the module is not present", 3
      if $@;

    # XXX: this eval thing doesn't seem to work right.

    # 'require Readonly' as above can be used to test if the module is
    # present, but won't actually work.  So below we 'use Readonly',
    # but in a string eval.
    eval q{
        use Readonly;

        Readonly my $expires => 3;

        Readonly my $key2 => "Третий.ключ";
        ok($memd->set($key2, $key2, $expires));
        ok(exists $memd->get_multi($key2)->{$key2});
        sleep(4);
        ok(! exists $memd->get_multi($key2)->{$key2});
    };
}

