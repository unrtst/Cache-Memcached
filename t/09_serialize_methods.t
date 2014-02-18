#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

BEGIN {
    require "t/test_structs.pl";
}

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 48;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

close $msock;

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    # disable compression so it does not get in the way
    compress_enable => 0,
    # fake in a serialize method just to test its getting called ok
    serialize_methods => [
        sub { "AAAAAAAAAAC" },
        sub { "DAAAAAAAAAA" },
    ],
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd->enable_compress(0);

ok($memd->set("key1", get_small_struct()), "set key1 to small struct");
is($memd->get("key1"), "DAAAAAAAAAA",      "get key1 gets expected value");

ok($memd->set("key2", get_jvm_struct()),   "set key1 to jvm struct");
is($memd->get("key2"), "DAAAAAAAAAA",      "get key2 gets expected value");

# make a new instance that lets us peek at the raw values
my $memd2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 0,
    # set thawed value to the raw data from memcached
    serialize_methods => [
        sub { $_[0] },
        sub { $_[0] },
    ]
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd2->enable_compress(0);

is($memd2->get("key1"), "AAAAAAAAAAC", "get unthawed key1");
is($memd2->get("key2"), "AAAAAAAAAAC", "get unthawed key2");

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
ok($memd->delete("key2"), "delete key2");


# try some other actual serialization modules
my %other_modules = (
    'Storable'  => {
        libs    => [ qw( Storable ) ],
        meths   => [
            sub { Storable::nfreeze( $_[0] ) },
            sub { Storable::thaw( $_[0] ) },
        ],
    },
    'Data::MessagePack' => {
        libs    => [ qw( Data::MessagePack ) ],
        meths   => [
            sub { Data::MessagePack::pack( $_[0] ) },
            sub { Data::MessagePack::unpack( $_[0] ) },
        ],
    },
    'JSON::PP'  => {
        libs    => [ qw( JSON::PP ) ],
        meths   => [
            sub { JSON::PP::encode_json( $_[0] ) },
            sub { JSON::PP::decode_json( $_[0] ) },
        ],
    },
    'JSON::XS'  => {
        libs    => [ qw( JSON::XS ) ],
        meths   => [
            sub { JSON::XS::encode_json( $_[0] ) },
            sub { JSON::XS::decode_json( $_[0] ) },
        ],
    },
    'Data::Dumper'  => {
        libs    => [ qw( Data::Dumper ) ],
        meths   => [
            sub { Data::Dumper::Dumper( $_[0] ) },
            sub { my $t = eval $_[0]; return $t unless $@ },
        ],
    },
);

foreach my $subtest (keys %other_modules) {
    SKIP: {
        LOADLIB:
        foreach my $lib ( @{ $other_modules{$subtest}{libs} } ) {
            eval "require $lib";
            if ($@) {
                skip "$lib not installed", 8;
                last LOADLIB;
            }
        }

        # Special stuff for Data::Dumper (doesn't turn to have it on anyway)
        no warnings 'once';
        local $Data::Dumper::Indent     = 0;
        local $Data::Dumper::Purity     = 1;
        local $Data::Dumper::Useqq      = 1;
        local $Data::Dumper::Terse      = 1;
        local $Data::Dumper::Deepcopy   = 1;

        my $memd = Cache::Memcached->new({
            servers   => [ $testaddr ],
            namespace => $namespace,
            compress_enable => 0,
            # add the methods we're testing...
            serialize_methods => $other_modules{$subtest}{meths},
        });
        # Cache::Memcached <= 1.30 does not set enable_compress via new
        $memd->enable_compress(0);

        ok($memd->set("key1", get_small_struct()),        "[$subtest] set key1 to small struct");
        is_deeply($memd->get("key1"), get_small_struct(), "[$subtest] get key1 is small struct");

        ok($memd->set("key2", get_jvm_struct()),        "[$subtest] set key1 to jvm struct");
        is_deeply($memd->get("key2"), get_jvm_struct(), "[$subtest] get key2 is jvm struct");


        # make a new instance that lets us peek at the raw values
        my $memd2 = Cache::Memcached->new({
            servers   => [ $testaddr ],
            namespace => $namespace,
            compress_enable => 0,
            # set thawed value to the raw data from memcached
            serialize_methods => [
                sub { $_[0] },
                sub { $_[0] },
            ]
        });
        # Cache::Memcached <= 1.30 does not set enable_compress via new
        $memd2->enable_compress(0);

        ok($memd2->get("key1"),  "[$subtest] get unthawed key1 got something");
        ok( ! ref( $memd2->get("key1") ), "[$subtest] get unthawed key1 got non-ref");
        # ... really need some sort of way to do isnt_deeply or something like that.
        #     oh well... above tests are probably sufficient

        # clean up after ourselves
        ok($memd->delete("key1"), "[$subtest] delete key1");
        ok($memd->delete("key2"), "[$subtest] delete key2");
    };
}

