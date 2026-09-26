use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Net::HTTP2::nghttp2 qw(NGHTTP2_NO_ERROR);
use Net::HTTP2::nghttp2::Session;
use Test::HTTP2::Frame qw(
    CLIENT_PREFACE FRAME_GOAWAY
    build_settings_frame build_headers_frame parse_frames
);
use Test::HTTP2::HPACK qw(encode_headers);

my @closed;
my $server = Net::HTTP2::nghttp2::Session->new_server(
    callbacks => {
        on_begin_headers => sub { return 0 },
        on_header        => sub { return 0 },
        on_frame_recv    => sub { return 0 },
        on_stream_close  => sub {
            push @closed, [@_];
            return 0;
        },
    },
);

$server->send_connection_preface;
$server->mem_send;
$server->mem_recv(CLIENT_PREFACE . build_settings_frame());
$server->mem_send;

my $request = encode_headers([
    [':method', 'POST'],
    [':path', '/'],
    [':scheme', 'https'],
    [':authority', 'example.test'],
]);
$server->mem_recv(build_headers_frame(
    stream_id    => 1,
    header_block => $request,
    end_stream   => 0,
    end_headers  => 1,
));
$server->mem_send;

is($server->get_stream_remote_close(1), 0,
    'request stream is open before local reset');

is($server->submit_rst_stream(1, NGHTTP2_NO_ERROR), 0,
    'server accepts local reset');
my $reset_wire = $server->mem_send;
ok(length $reset_wire, 'reset was serialized but not delivered to the peer');

my $after_reset = $server->get_stream_remote_close(1);
diag('remote-close after serialized reset: ' .
    (defined($after_reset) ? $after_reset : 'undef'));
diag('stream-close callbacks: ' . scalar @closed);

my $trailers = encode_headers([
    ['x-late-trailer', 'still-in-flight'],
]);
my $rv = eval {
    $server->mem_recv(build_headers_frame(
        stream_id    => 1,
        header_block => $trailers,
        end_stream   => 1,
        end_headers  => 1,
    ));
};
diag('late HEADERS mem_recv: ' . (defined($rv) ? $rv : 'died: ' . $@));

my ($frames) = parse_frames($server->mem_send);
my @goaway = grep { $_->{type} == FRAME_GOAWAY } @$frames;
is(scalar @goaway, 0,
    'late peer HEADERS racing with an undelivered reset is not a connection error');

done_testing;
