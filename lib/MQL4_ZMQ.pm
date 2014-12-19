package MQL4_ZMQ;

#-------------------------------------------------------------------------------------------------
# Letzte Aenderung:     $Date: $
#                       $Revision: $
#                       $Author: $
#
# Aufgabe:    - ZeroMQ Kommunikation
#             - Implementierung MT4 Telegramme
#
#
# $Id: $
#-------------------------------------------------------------------------------------------------

use v5.10;
use strict;
use vars qw($VERSION $SVN $OVERSION);

use constant SVN_ID => '($Id: $)

$Author: $ 

$Revision: $ 
$Date: $ 
';

($VERSION = SVN_ID) =~ s/^(.*\$Revision: )([0-9]*)(.*)$/1.0 R$2/ms;
$SVN      = $VERSION . ' ' . SVN_ID;
$OVERSION = $VERSION;

use base 'Exporter';

our @EXPORT    = ();
our @EXPORT_OK = ();

use vars @EXPORT, @EXPORT_OK;

use vars qw(@ISA);
@ISA = qw();

use FindBin qw($Bin $Script $RealBin $RealScript);

use Trace;
use CmdLine;
use Configuration;
use Utils;

#
# Module
#
use JSON::PP;
use ZMQ::LibZMQ3;
use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_PUB ZMQ_SUB ZMQ_DONTWAIT ZMQ_SUBSCRIBE);
use Time::HiRes q(usleep);

#
# Konstantendefinition
#

#
# Variablendefinition
#

#
# Methodendefinition
#
sub version {
  my $self     = shift();
  my $pversion = shift();

  $OVERSION =~ m/^([^\s]*)\sR([0-9]*)$/;
  my ($oVer, $oRel) = ($1, $2);
  $oVer = 1 if (!$oVer);
  $oRel = 0 if (!$oRel);

  if (defined($pversion)) {
    $pversion =~ m/^([^\s]*)\sR([0-9]*)$/;
    my ($pVer, $pRel) = ($1, $2);
    $pVer = 1 if (!$pVer);
    $pRel = 0 if (!$pRel);
    $VERSION = $oRel gt $pRel ? "$pVer R$oRel" : "$pVer R$pRel";
  }

  return wantarray() ? ($VERSION, $OVERSION) : $VERSION;
}


sub new {
  #################################################################
  #     Legt ein neues Objekt an
  my $self  = shift;
  my $class = ref($self) || $self;
  my @args  = @_;

  my $ptr = {};
  bless $ptr, $class;
  $ptr->_init(@args);

  return $ptr;
}


sub _init {
  #################################################################
  #   Initialisiert ein neues Objekt
  my $self = shift;
  my @args = @_;

  $self->{Startzeit} = time();
  
  $VERSION = $self->version(shift(@args));
 
  Trace->Trc('S', 1, 0x00001, Configuration->prg, $VERSION . " (" . $$ . ")" . " Test: " . Trace->test() . " Parameter: " . CmdLine->new()->{ArgStrgRAW});

  # MQL4 Initialisierung
  $self->{Uid}     = Configuration->config('MQL4_ZMQ', 'Uid');
  $self->{Account} = Configuration->config('MQL4_ZMQ', 'Account');
  $self->{JSON}    = JSON::PP->new->utf8;
  
  # ZeroMQ Initialisierung
  #### pub/sub ####
  $self->{Context}  = ZMQ::FFI->new();
  $self->{Endpoint} = Utils::extendString(Configuration->config('MQL4_ZMQ', 'Endpoint'), "BIN|$Bin|SCRIPT|" . uc($Script));

  ### here pub ####
  $self->{PubSock}  = $self->{Context}->socket(ZMQ_PUB);
  $self->{PubSock}->bind($self->{Endpoint});
  
  ### here Sub ####
  $self->{SubSock} = $self->{Context}->socket(ZMQ_SUB);
  $self->{SubSock}->connect($self->{Endpoint});
  $self->{SubSock}->subscribe("response|" . $self->{Account});
}


sub DESTROY {
  #################################################################
  #     Zerstoert das Objekt an
  my $self = shift;
  my ($rc, $sig) = (0,0);
  $rc  = ($? >> 8);
  $sig = $? & 127;
  if ($@ || $rc != 0 || $sig != 0) {
    my ( $routine, $i ) = ( ( caller(0) )[3] . ':', 0 );
    while ( defined( caller( ++$i ) ) ) {
      $routine .= ( caller($i) )[3] . '(' . ( caller( $i - 1 ) )[2] . '):';
    }
    Trace->Trc('S', 1, 0x00007, "$routine $@ $! $?");
    Trace->Log('Log', 0x10013, $@, $!, $?);
  }
  for my $parent (@ISA) {
    if ( my $coderef = $self->can( $parent . "::DESTROY" ) ) {
      $self->$coderef();
    }
  }
  # Eigentlich nicht noetig, da -autoclean => 1
  if ($self->{Lock}) {$self->{Lock}->unlock($self->{LockFile})}
}


sub getInfo {
  #################################################################
  #     Kommunikation mit dem MT4
  #     Proc 1
  #     Eingabe: Argumenthash mit mindestens einem Element 'cmd'
  #              mit Elementen: typ:  status|info
  #                             wert: bridge|tick|account|ema|order
  #              Mögliche Wert: status   -> bridge
  #                             info     -> tick
  #                             info     -> account
  #                             info     -> ema
  #                             info     -> order
  #     Ausgabe: Status der Bridge
  #
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;

  # Subscriber must do
  # Initialisation
  $self->{SubSock}->subscribe($args{typ} . '|' . $self->{Account} . ' ' . $args{typ});
    
  # Data Transfer
  # say $self->{ZMQ}->{SubSock}->recv();

  $rc = $self->{SubSock}->recv();
    
  # CleanUp
  $self->{SubSock}->unsubscribe($args{typ} . '|' . $self->{Account} . ' ' . $args{typ});

  if ($rc) {
    Trace->Trc('I', 1, 0x02901, $args{typ} . '|' . $self->{Account} . ' ' . $args{typ}, $rc);
  } else {
    Trace->Trc('I', 1, 0x0a900, $args{typ} . '|' . $self->{Account} . ' ' . $args{typ});
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub cmd {
  #################################################################
  #     Kommunikation mit dem MT4
  #     Proc 2
  #     Eingabe: Argumenthash mit mindestens einem Element 'cmd'
  #     
  #  Kommando get: 
  #
  #    Request Value: cmd|[account name]|[uid] {"cmd":   "set",
  #                                             "value": "[abgefragter Wert]"}
  #                       
  #    Response: [Ergebnis]
  #              EURUSD
  #
  #
  #  Kommando set:
  #
  #    New Trade/Order: cmd|[account name]|[uid] {"cmd":          "set",
  #                                               "type":         "[Orderart]", 
  #                                               "pair":         "[gehandeltes Symbol]", 
  #                                               "open_price":   "[Eröffnungskurs]",
  #                                               "slippage":     "[Slippage]", 
  #                                               "magic_number": "[Magic Number]", 
  #                                               "comment":      "[Kommentar]", 
  #                                               "take_profit":  "[TakeProfit]", 
  #                                               "stop_loss":    "[StoppLoss]", 
  #                                               "lot":          "[Anzahl Lots]"}
  #
  #    Response: Order has been processed.
  #                
  #    Trade Types:
  #       0 = (MQL4) OP_BUY       - buying position,
  #       1 = (MQL4) OP_SELL      - selling position,
  #       2 = (MQL4) OP_BUYLIMIT  - buy limit pending position,
  #       3 = (MQL4) OP_SELLLIMIT - sell limit pending position,
  #       4 = (MQL4) OP_BUYSTOP   - buy stop pending position,
  #       5 = (MQL4) OP_SELLSTOP  - sell stop pending position.
  #  
  #  
  #  Kommando reset:
  #   
  #    Update Trade:  cmd|[account name]|[uid] {"cmd":         "reset",
  #                                             "ticket":      "[Ticket ID]", 
  #                                             "take_profit": "[TakeProfit]", 
  #                                             "stop_loss":   "[StoppLoss]"}
  #
  #    Update Order neu:  cmd|[account name]|[uid] {"cmd":         "reset",
  #                                                 "ticket":      "[Ticket ID]", 
  #                                                 "take_profit": "[TakeProfit]", 
  #                                                 "stop_loss":   "[StoppLoss]",
  #                                                 "open_price":  "[Eröffnungskurs]"}
  #    
  #    Response: Order has been processed.
  #
  #
  #  Kommando unset:
  #
  #    Close Trade/Order: cmd|[account name]|[uid] {"cmd":    "unset",
  #                                                 "ticket": "[Ticket ID]"}
  #
  #    Response: Order has been processed.
  #     
  #  Kommando draw:
  #
  #    Draw Object:   cmd|[account name]|[uid] {"cmd":         "draw",
  #                                             "obj_type":    "[Objekt Type]", 
  #                                             "open_price":  "[Eröffnungskurs]", 
  #                                             "close_price": "[Schlußkurs]",
  #                                             "close_time":  "[Schlußzeit]",
  #                                             "prediction":  "[Prediction]"}
  #
  #    Response: true|false
  #     
  #  Kommando parameter:
  #
  #  Request Value: cmd|[account name]|[uid] {"cmd":   "parameter",
  #                                           "value": "[zu setzender Parameter]"}
  #                 cmd|testaccount|fdjksalr38wufsd= {"cmd":   "set",
  #                                                   "value": "Wait_for_Message=0"}
  #                     
  #  Response: -
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;

  if (defined($args{cmd})) {
    my $cmd = "cmd|$self->{Account}|$self->{Uid} $self->{JSON}->utf8(0)->encode(\%args)";
    #  if (defined($self->{Store}->{Signal}->{$id}) && (ref($self->{Store}->{Signal}->{$id}) eq 'HASH')) {
    #    while ((my $key, my $value) = each(%{$self->{Store}->{Signal}->{$id}})) {
    #      $telegramm .= "$key|$value|";
    #    }
    #  }

    Trace->Trc('I', 1, 0x02900, $cmd);

    $self->{PubSock}->send($cmd, ZMQ_DONTWAIT);
    usleep 100_000;
    my $rc = $self->{SubSock}->recv();
    
    # Response:   response|[account name]|[uid] {"response": "[response]"}
    #
    # Responses:  true
    #             false
    #             Order has been send:[Ticket ID]
    #             Order has been modified.
    #             Order has been closed.
    #             [pair]
    #
    if      ($args{cmd} eq 'get') {
      #    Response: [Ergebnis]
      #              EURUSD
    } elsif ($args{cmd} eq 'set') {
      #    Response: Order has been send:[Ticket ID]
      if ($rc =~ /^Order has been send:(.*)$/) {
        $rc = $1;
      }
    } elsif ($args{cmd} eq 'reset') {
      #    Response: Order has been modified.
      $rc = ($rc eq 'Order has been modified.');
    } elsif ($args{cmd} eq 'unset') {
      #    Response: Order has been closed.
      $rc = ($rc eq 'Order has been closed.');
    } elsif ($args{cmd} eq 'draw') {
      #    Response: true|false
      $rc = ($rc eq 'true');
    } elsif ($args{cmd} eq 'parameter') {
      #    Response: 1
      $rc = 1;
    } else {
      # unbekanntes Kommando
      $rc = 0;
    }

    # Subscriber must do
    # Initialsation
    # $self->{ZMQ}->{SubSock}->subscribe('');
    
    # Data Transfer
    # say $self->{ZMQ}->{SubSock}->recv();

    # CleanUp
    # $self->{ZMQ}->{SubSock}->unsubscribe('');

    if ($rc) {
      # Operation erfolgreich. Signal ist aktiviert(open) oder deaktiviert(close)
      #$self->{Store}->{Signal}->{$id}->{Activ} = ($op eq 'open');
      Trace->Trc('I', 1, 0x02901, $cmd, $rc);
    } else {
      Trace->Trc('I', 1, 0x0a900, $cmd);
    }
  } else {
    # @@@ kein Kommando vorhanden
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}



1;
