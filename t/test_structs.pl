use strict;

# Data structures here copied from:
#     https://github.com/pmakholm/benchmark-serialize-perl
# ...specifically:
#     https://github.com/pmakholm/benchmark-serialize-perl/blob/master/benchmarks/small/structure.pl
#     https://github.com/pmakholm/benchmark-serialize-perl/blob/master/benchmarks/jvm-serializers/structure.pl

my %structs = (
    'small'             => { a => 1 },
    'jvm-serializers'   => {
        media => {
            uri => "http://javaone.com/keynote.mpg",
            title => "Javaone Keynote",
            width => 640,
            height => 480,
            format => "video/mpg4",
            duration => 18000000,    # half hour in milliseconds
            size => 58982400,        # bitrate * duration in seconds / 8 bits per byte
            bitrate => 262144,  # 256k
            person => ["Bill Gates", "Steve Jobs"],
            player => 0,
            copyright => "None",
        },
        image => [
            {
                uri => "http://javaone.com/keynote_large.jpg",
                title => "Javaone Keynote",
                width => 1024,
                height => 768,
                size => 1,
            },
            {
                uri => "http://javaone.com/keynote_small.jpg",
                title => "Javaone Keynote",
                width => 320,
                height => 240,
                size => 0,
            }
        ]
    },
);

sub get_small_struct
{
    return $structs{small};
}

sub get_jvm_struct
{
    return $structs{'jvm-serializers'};
}

1;
