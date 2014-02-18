#!/usr/bin/env perl -w

use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => 89;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

close $msock;

my $namespace = "Cache::Memcached::t/$$/" . (time() % 100) . "/";

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 1,
    # set compress_threshold small so we don't need big values
    compress_threshold => 500, # bytes
    # COMPRESS_SAVINGS stuck at 20%
    # fake in a compress method just to test its getting called ok
    compress_methods => [
        sub { ${$_[1]} = substr( ${$_[0]}, 0, 10 )."C" },
        sub { ${$_[1]} = "D".substr( ${$_[0]}, 0, 10 ) },
    ],
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd->enable_compress(1);


# stick in a value that is highly compressable
ok($memd->set("key1", "".("A" x (1024*512)) ), "set key1 to 512k of repeated 'A'");
is($memd->get("key1"), "DAAAAAAAAAA",          "get key1 gets expected value");

# make a big random string
my $rand;
$rand .= chr(rand(255)) for 1 .. (1024*256);

ok($memd->set("key2", $rand), "set key2 to 512k of repeated 'A'");
is($memd->get("key2"), "D".substr($rand, 0, 10), "get key2 gets expected value");

# make a new instance that lets us peek at the uncompresed value
my $memd2 = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => $namespace,
    compress_enable => 0, # this does not disable decompression
    # set decompressd to the raw data from memcached
    compress_methods => [
        sub { ${$_[1]} = ${$_[0]} },
        sub { ${$_[1]} = ${$_[0]} },
    ]
});
# Cache::Memcached <= 1.30 does not set enable_compress via new
$memd2->enable_compress(0);

is($memd2->get("key1"), "AAAAAAAAAAC",            "get compressed key1");
is($memd2->get("key2"), substr($rand, 0, 10)."C", "get compressed key2");

# clean up after ourselves
ok($memd->delete("key1"), "delete key1");
ok($memd->delete("key2"), "delete key2");


# try some other actual compression modules
my %other_modules = (
    'IO::Compress::Bzip2' => {
        libs    => [qw( IO::Compress::Bzip2 IO::Uncompress::Bzip2 )],
        meths   => [ \&IO::Compress::Bzip2::bzip2, \&IO::Uncompress::Bzip2::bunzip2 ],
    },
    'IO::Compress::Deflate' => {
        libs    => [qw( IO::Compress::Deflate IO::Uncompress::Inflate )],
        meths   => [ \&IO::Compress::Deflate::deflate, \&IO::Uncompress::Inflate::inflate ],
    },
    'IO::Compress::Gzip' => {
        libs    => [qw( IO::Compress::Gzip IO::Uncompress::Gunzip )],
        meths   => [ \&IO::Compress::Gzip::gzip, \&IO::Uncompress::Gunzip::gunzip ],
    },
    'IO::Compress::RawDeflate' => {
        libs    => [qw( IO::Compress::RawDeflate IO::Uncompress::RawInflate )],
        meths   => [ \&IO::Compress::RawDeflate::rawdeflate, \&IO::Uncompress::RawInflate::rawinflate ],
    },
    'IO::Compress::Zip' => {
        libs    => [qw( IO::Compress::Zip IO::Uncompress::Unzip )],
        meths   => [ \&IO::Compress::Zip::zip, \&IO::Uncompress::Unzip::unzip ],
    },
    'Compress::LZ4' => {
        libs    => ['Compress::LZ4'],
        meths   => [
            sub { ${$_[1]} = Compress::LZ4::compress( ${$_[0]} ) },
            sub { ${$_[1]} = Compress::LZ4::decompress( ${$_[0]} ) },
        ],
    },
    'Compress::Bzip2' => {
        libs    => ['Compress::Bzip2'],
        meths   => [
            sub { ${$_[1]} = Compress::Bzip2::memBzip( ${$_[0]} ) },
            sub { ${$_[1]} = Compress::Bzip2::memBunzip( ${$_[0]} ) },
        ],
    },
    'Compress::LZF' => {
        libs    => ['Compress::LZF'],
        meths   => [
            sub { ${$_[1]} = Compress::LZF::compress( ${$_[0]} ) },
            sub { ${$_[1]} = Compress::LZF::decompress( ${$_[0]} ) },
        ],
    },
    'Compress::Snappy' => {
        libs    => ['Compress::Snappy'],
        meths   => [
            sub { ${$_[1]} = Compress::Snappy::compress( ${$_[0]} ) },
            sub { ${$_[1]} = Compress::Snappy::decompress( ${$_[0]} ) },
        ],
    },
);

foreach my $subtest (keys %other_modules) {
    SKIP: {
        LOADLIB:
        foreach my $lib ( @{ $other_modules{$subtest}{libs} } ) {
            eval "require $lib";
            if ($@) {
                skip "$lib not installed", 9;
                last LOADLIB;
            }
        }

        my $memd = Cache::Memcached->new({
            servers   => [ $testaddr ],
            namespace => $namespace,
            compress_enable => 1,
            # set compress_threshold small so we don't need big values
            compress_threshold => 500, # bytes
            # COMPRESS_SAVINGS stuck at 20%
            # add the methods we're testing...
            compress_methods => $other_modules{$subtest}{meths},
        });
        # Cache::Memcached <= 1.30 does not set enable_compress via new
        $memd->enable_compress(1);


        # stick in a value that is highly compressable
        ok($memd->set("key1", "".("A" x (1024*512)) ), "[$subtest] set key1 to 512k of repeated 'A'");
        is($memd->get("key1"), "".("A" x (1024*512)),  "[$subtest] get key1 is same string");

        # make a big random string
        my $rand;
        $rand .= chr(rand(255)) for 1 .. (1024*256);

        ok($memd->set("key2", $rand), "[$subtest] set key2 to 512k of repeated 'A'");
        is($memd->get("key2"), $rand, "[$subtest] get key2 is same string");

        # make a new instance that lets us peek at the uncompresed value
        my $memd2 = Cache::Memcached->new({
            servers   => [ $testaddr ],
            namespace => $namespace,
            compress_enable => 0, # this does not disable decompression
            # set decompressd to the raw data from memcached
            compress_methods => [
                sub { ${$_[1]} = ${$_[0]} },
                sub { ${$_[1]} = ${$_[0]} },
            ]
        });
        # Cache::Memcached <= 1.30 does not set enable_compress via new
        $memd2->enable_compress(0);

        ok($memd2->get("key1"),  "[$subtest] get compressed key1 got something");
        isnt($memd2->get("key1"), "".("A" x (1024*512)),  "[$subtest] get compressed key1 is different string");
        cmp_ok( length($memd2->get("key1")), '<', (1024*512),  "[$subtest] get compressed key1 is smaller than original");

        # clean up after ourselves
        ok($memd->delete("key1"), "[$subtest] delete key1");
        ok($memd->delete("key2"), "[$subtest] delete key2");
    };
}


