#!/usr/bin/env perl -w

# NOTE: basic tests borrowed from Cache::Memcached::Fast

# NOTE: this test passed before adding thread support to Cache::Memcached,
#       so it's not really of much value. That support came from:
#       https://rt.cpan.org/Public/Bug/Display.html?id=54515

use warnings;
use strict;
use Test::More;
use Cache::Memcached;
use IO::Socket::INET;

unless ($^V) {
    plan skip_all => "This test requires perl 5.6.0+\n";
    exit 0;
}
if ($^V lt v5.7.2) {
   plan skip_all => 'Perl >= 5.7.2 is required';
    exit 0;
}

use Config;
unless ($Config{useithreads}) {
   plan skip_all => 'ithreads are not configured';
}

use constant COUNT => 5;

my $testaddr = "127.0.0.1:11211";
my $msock = IO::Socket::INET->new(PeerAddr => $testaddr,
                                  Timeout  => 3);
if ($msock) {
    plan tests => COUNT * 2;
} else {
    plan skip_all => "No memcached instance running at $testaddr\n";
    exit 0;
}

my $memd = Cache::Memcached->new({
    servers   => [ $testaddr ],
    namespace => "Cache::Memcached::t/$$/" . (time() % 100) . "/",
});


require threads;

sub job {
    my ($num) = @_;

    $memd->set($num, $num);
}

my @threads;
for my $num (1..COUNT) {
    push @threads, threads->new(\&job, $num);
}

for my $num (1..COUNT) {
    $threads[$num - 1]->join;

    my $n = $memd->get($num);
    is($n, $num);
    ok($memd->delete($num));
}

