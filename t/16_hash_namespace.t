#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;
use String::CRC32;

plan tests => 606;


# NOTE: The key distribution, as it relates to the hash_prefix, is very
#       sensitive to both the namespace string and number of servers.
#       This is because the crc32 of the namespace could be something which
#       has little effect on the keys were testing, or could always result in
#       a key that is evenly divisible by 2 with keys of "key1 .. key200",
#       etc... anyway, this one has been tested to work with between 2 and 5
#       servers with keys of "key1" .. "key200" and produce at least some
#       differences in distribution.
my $namespace = "Cache::Memcached::t/hash_namespace/";

# test method directly first (only reliable way to test it, since it only affects selected server)
my $CM_1_30_hash = (crc32($namespace) >> 16) & 0x7fff;
my $no_hash_namespace = Cache::Memcached::_hashfunc($namespace, 0);
my $hash_namespace    = Cache::Memcached::_hashfunc($namespace, crc32($namespace));

cmp_ok($CM_1_30_hash, 'eq', $no_hash_namespace, "defaults produce hash matching Cache::Memcached 1.30 hashes");
cmp_ok($hash_namespace, 'ne', $no_hash_namespace, "hash_namespace produces different result than default");



# testing further (actually setting keys) requires at least 2 servers
my @testaddr = qw(127.0.0.1:11211 127.0.0.1:11212 127.0.0.1:11213
                  127.0.0.1:11214 127.0.0.1:11215);
my @ok_addrs;
foreach my $testaddr (@testaddr) {
    my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                      Timeout  => 3);
    push(@ok_addrs, $testaddr) if $msock;
    close $msock if $msock;
}

# redo basic tests using values from the instance if we get any connections
SKIP: {
    skip "Requires at least one server.", 2
        unless @ok_addrs;

    my $mem1 = Cache::Memcached->new({
        servers   => [ @ok_addrs ],
        namespace => $namespace,
    });

    my $mem2 = Cache::Memcached->new({
        servers   => [ @ok_addrs ],
        namespace => $namespace,
        hash_namespace  => 1,
    });

    my $CM_1_30_hash = (crc32($namespace) >> 16) & 0x7fff;
    my $no_hash_namespace = Cache::Memcached::_hashfunc($namespace, $mem1->{'prefix_hash'});
    my $hash_namespace    = Cache::Memcached::_hashfunc($namespace, $mem2->{'prefix_hash'});

    cmp_ok($CM_1_30_hash, 'eq', $no_hash_namespace, "defaults produce hash matching Cache::Memcached 1.30 hashes");
    cmp_ok($hash_namespace, 'ne', $no_hash_namespace, "hash_namespace produces different result than default");
};


SKIP: {
    skip "Further test require more than one server.", 602
        unless @ok_addrs > 1;

    # if we stick a bunch of values in one without hash_namespace,
    # and then try to get them with one that has hash_namespace,
    # we should have a different distribution and get a bunch of misses.

    my $mem1 = Cache::Memcached->new({
        servers   => [ @ok_addrs ],
        namespace => $namespace,
    });

    my $mem2 = Cache::Memcached->new({
        servers   => [ @ok_addrs ],
        namespace => $namespace,
        hash_namespace  => 1,
    });

    my $mem2_get_fail_count = 0;
    for (1..200) {
        my ($key, $val) = ("key$_", "val$_");
        ok($mem1->set($key, $val), "[mem1] set $key as $val");
        is($mem1->get($key), $val, "[mem1] get $key is $val");

        my $mem2_val = $mem2->get($key);
        $mem2_get_fail_count++ unless $mem2_val;

        # clean up after ourselves
        ok($mem1->delete($key), "[mem1] delete $key");
    }

    # at lesat some should be on different servers
    cmp_ok($mem2_get_fail_count, '>', 10, "hash_namespace modified key distribution");
    # at least some should end up on the same servers
    cmp_ok($mem2_get_fail_count, '<', 199, "hash_namespace did not cause everything to move");

};

