#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

unless ($^V) {
    plan skip_all => "This test requires perl 5.6.0+\n";
    exit 0;
}

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 9;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

##############################################################################
# This is connecting to TEST-NET-1 on purpose, because that's a space that is
# guaranteed by RFC to have no hosts in it. Sometimes we still get fast RST
# frames though, so we have to check before we trust it.
#
# DO NOT FIX THIS CODE TO CHECK AND MAKE SURE THE HOST IS UP. IT IS SUPPOSED
# TO BE DOWN. :) --hachi
##############################################################################
# this is used to test how server_versions behaves with a down host
my $downaddr = "192.0.2.1:11211";


my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => "Cache::Memcached::t/$$/" . (time() % 100) . "/",
});

isa_ok($memd, 'Cache::Memcached');

my $version = $memd->server_versions;
ok(ref $version,                     "server_versions returns ref");
ok(exists $version->{$testaddr},     "server_versions returned a key with testaddr '$testaddr'");
ok(length $version->{$testaddr} > 0, "length of version for '$testaddr' is possitive");
diag("version of $testaddr is: $version->{$testaddr}");

# try with a bogus server...
my $mem2 = Cache::Memcached->new({
    servers   => [ $testaddr, $downaddr ],
    namespace => "Cache::Memcached::t/$$/" . (time() % 100) . "/",
});

isa_ok($mem2, 'Cache::Memcached');

$version = $mem2->server_versions;
ok(ref $version,                     "server_versions returns ref");
ok(exists $version->{$testaddr},     "server_versions returned a key with testaddr '$testaddr'");
ok(length $version->{$testaddr} > 0, "length of version for '$testaddr' is possitive");
ok(! exists $version->{$downaddr},   "server_versions did not return an entry for downaddr '$downaddr'");


