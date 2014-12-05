eval 'exec perl -wS $0 ${1+"$@"}'
  if 0;

use v5.10;
use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_PUB ZMQ_SUB ZMQ_DONTWAIT);
use Time::HiRes q(usleep);

use diagnostics;

my $endpoint = "tcp://iMac:5555";
say "Endpoint defined: $endpoint";
my $ctx      = ZMQ::FFI->new();
say "Context defined.";

my $s = $ctx->socket(ZMQ_SUB);
say "Socket defined.";

$s->connect($endpoint);
say "Connected to Socket.";

# all topics
$s->subscribe('');
say "Subscribed for everything.";
while (1) {
  say "Waiting....";
#  $p->send('ohhai', ZMQ_DONTWAIT);
#
#  until ($s->has_pollin) {
#    # compensate for slow subscriber
#    usleep 100_000;
#    $p->send('ohhai', ZMQ_DONTWAIT);
#  }

  say $s->recv();
  # ohhai
}
$s->unsubscribe('');
