use strict;
use warnings;

# required modules
use Net::IMAP::Simple;
use Email::Simple;
use IO::Socket::SSL;

# fill in your details here
my $username = 'pp2.privat@gmail.com';
my $password = 'tina1999';
my $mailhost = 'imap.gmail.com';

# Connect
my $imap = Net::IMAP::Simple->new(
    $mailhost,
    port    => 993,
    use_ssl => 1,
) || die "Unable to connect to IMAP: $Net::IMAP::Simple::errstr\n";

# Log in
if ( !$imap->login( $username, $password ) ) {
    print STDERR "Login failed: " . $imap->errstr . "\n";
    exit(64);
}
# Look in the the INBOX
my $nm = $imap->select('INBOX');

# How many messages are there?
my ($unseen, $recent, $num_messages) = $imap->status();
print "unseen: $unseen, recent: $recent, total: $num_messages\n\n";


## Iterate through unseen messages
for ( my $i = 1 ; $i <= $nm ; $i++ ) {
    if ( $imap->seen($i) ) {
        next;
    }
    else {
    my $es = Email::Simple->new( join '', @{ $imap->top($i) } );

    printf( "[%03d] %s\n\t%s\n", $i, $es->header('From'), $es->header('Subject') );
    }
}


# Disconnect
$imap->quit;

exit;