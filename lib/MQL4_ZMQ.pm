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
use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_PUB ZMQ_REP ZMQ_DONTWAIT ZMQ_SUBSCRIBE ZMQ_NOBLOCK);
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
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 1, 0x00101, $self->{subroutine}, "Parameter: " . join(' ', %args));
  
  my $rc = 0;

  # Initialisierung JSON Objekt
  $self->{JSON}    = JSON::PP->new->utf8;
  
  # ZeroMQ Initialisierung pub/sub
  #### Context
  $self->{Context} = ZMQ::FFI->new();
  my ($major, $minor, $patch) = $self->{Context}->version;
  Trace->Trc('S', 1, "ZMQ Version ${major}.${minor}.${patch}");

  ### Reply ####
  $self->{RepAddr} = Utils::extendString($args{RepAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{RepSock} = $self->{Context}->socket(ZMQ_REP);
  $self->_bindSocket('Socket', 'RepSock', 'Addr', 'RepAddr');

  ### Publisher ####
  $self->{PubAddr} = Utils::extendString($args{PubAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{PubSock} = $self->{Context}->socket(ZMQ_PUB);
  $self->_bindSocket('Socket', 'PubSock', 'Addr', 'PubAddr');
  
  Trace->Trc('S', 1, 0x00102, $self->{subroutine});
  $self->{subroutine} = $merker;

  return 1;
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
    Trace->Trc('S', 1, 0x08fff, "$routine $@ $! $?");
  }
  for my $parent (@ISA) {
    if ( my $coderef = $self->can( $parent . "::DESTROY" ) ) {
      $self->$coderef();
    }
  }
  # Eigentlich nicht noetig, da -autoclean => 1
  if ($self->{Lock}) {$self->{Lock}->unlock($self->{LockFile})}
}


sub sendMT4 {
  #################################################################
  #     Kommandoversand an den MT4
  #     Proc 1
  #     Eingabe: Argumenthash mit mindestens den Elementen 
  #              cmd     : Auszuführendes Kommando
  #              account : Betroffenes Konto
  #              uuid    : UUID
  #
  #              Weitere moegliche Elemente:
  #              type        : Orderart
  #              pair        : gehandeltes Symbol
  #              open_price  : Eröffnungskurs
  #              slippage    : Slippage
  #              magic_number: Magic Number
  #              comment     : Kommentar
  #              take_profit : TakeProfit
  #              stop_loss   : StoppLoss 
  #              lot         : Anzahl Lots
  #              ticket      : Ticket ID 
  #              obj_type    : Objekt Type 
  #              close_price : Schlußkurs
  #              close_time  : Schlußzeit
  #              prediction  : Prediction
  #              name        : Parameter Name
  #              value       : abgefragter/zu setzender Wert
  #
  #    Ausgabe: 0: Fehler
  #             1: ok
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  if (defined($args{cmd})) {
    my $cmd = "$args{cmd}|$args{account} ";
    delete($args{cmd});
    delete($args{account});
    $cmd .= $self->{JSON}->utf8(0)->encode(\%args);

    Trace->Trc('I', 1, 0x03100, $cmd, ZMQ_DONTWAIT);

#    eval {$self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
#    if (!$@) {
    $rc = $self->_bindSocket('Socket', 'PubSock', 'Addr', 'PubAddr');

    if ($rc) {
      eval {$rc = $self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
      if ($@) {
        # Fehler
        $rc = 0;
        Trace->Trc('I', 1, 0x0b101, $cmd, $rc);
      } else {
        # Alles ok
        $rc = 1;
        Trace->Trc('I', 1, 0x03101, $cmd, $rc);
      }
    }
  } else {
    Trace->Trc('I', 1, 0x0b100, join(' ', %args));
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub readMT4 {
  #################################################################
  #     Abfrage der Antwort des MT4
  #     Proc 9
  #     Eingabe: Argumenthash mit den Werten
  #              account : Betroffenes Konto
  #
  #     Ausgabe: Argumenthash mit mindestens den Elementen 
  #              account : Betroffenes Konto
  #              msgtype : response|info|status
  #              msgsubj : bridge|tick|account|ema|order|<leer>
  
  #              uuid:     [UUID]
  #              cmd:      Original Kommando
  #              status  : Gesamtergebnis: 0: Nicht erfolgreich
  #                                        1: Erfolgreich
  #
  #              Weitere moegliche Elemente:
  #              ticket   : Ticket ID 
  #              msg      : Nachrichten Freitext
  #              name     : Parameter Name
  #              value    : abgefragter/zu setzender Wert
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;
  my $message;
  
  # Lese die gesamte Message aus der Queue
  $rc = $self->_bindSocket('Socket', 'RepSock', 'Addr', 'RepAddr');

  if ($rc) {
    eval {$message = $self->{RepSock}->recv(ZMQ_DONTWAIT)};
    if ($@) {
      # Fehler
      $rc = 0;
      $message = undef;
      Trace->Trc('I', 3, 0x0b600, $self->{RepAddr}, join(' ', $@));
    } else {
      # Alles ok
      $rc = 1;
      Trace->Trc('I', 2, 0x03600, $self->{RepAddr}, join(' ', $@));
    }
  }
  if ($message) {
    Trace->Trc('I', 2, 0x03900, $message);
    # Aufbau der Message
    # Statusmeldung: bridge|[account name] {"status": "up",
    #                                       "pair":   "[gehandeltes Symbol]", 
    #                                       "time":   "[aktueller Zeitstempel]"}
    #
    # Tickinfo:      tick|[account name] {"pair": "[gehandeltes Symbol]",
    #                                     "bid":  "[Geldkurs]",
    #                                     "ask":  "[Briefkurs]",
    #                                     "time": "[aktueller Zeitstempel]"}
    #
    # Accountinfo:   account|[account name] {"leverage":   "[Leverage]",
    #                                        "balance":    "[Balance]",
    #                                        "margin":     "[Margin]",
    #                                        "freemargin": "[freie Margin]"}          
    #
    # EMAinfo:       ema|[account name] {"pair":      "[gehandeltes Symbol]",
    #                                    "ema_long":  "[EMA long]",
    #                                    "ima_long":  "[iMA long]",
    #                                    "ema_short": "[EMA short]",
    #                                    "ima_short": "[iMA short]"}          
    #
    # Orders:       orders|[account name] {"pair":        "[gehandeltes Symbol]", 
    #                                      "type":        "[Orderart]", 
    #                                      "ticket":      "[Ticket ID]", 
    #                                      "open_price":  "[Eröffnungskurs]", 
    #                                      "take_profit": "[TakeProfit]", 
    #                                      "stop_loss":   "[StoppLoss]", 
    #                                      "open_time":   "[Eröffnungszeit]",  
    #                                      "expire_time": "[Gültigkeitsdauer]", 
    #                                      "lot":         "[Anzahl Lots]"}
    #
    # Response:      response|[account name] {"account":  "[Accountnummer]",
    #                                         "uuid":     "[UUID]",
    #                                         "cmd":      "get_parameter",
    #                                         "status":   "[0|1]",
    #                                         "msg":      "Parameter read [Name]:[Wert]",
    #                                         "name":     "[abgefragter Parameter]",
    #                                         "value":    "[abgefragter Wert]"}

    if ($message =~ /^(response|bridge|tick|account|ema|orders)\|$args{account} \{(.*)\}$/) {
      my $msgtype = $1;
      $message = $2;
      $rc = decode_json($message);
      Trace->Trc('I', 2, 0x03901, $message);
      $rc->{account} = $args{account};
      $rc->{msgtype} = $msgtype;
#      my $start_position = 0;
#      my $end_position = length($message);
#      while (($start_position >= 0) && ($end_position > $start_position)) {
#        $start_position = index('"', $message, 0) + 1;
#        $end_position   = index('"', $message, $start_position + 1);
#        if (($start_position >= 0) && ($end_position > $start_position)) {
#          my $key = lc(substr($message, $start_position, $end_position - $start_position));
#          $start_position = index('"', $message, $end_position) + 1;
#          $end_position   = index('"', $message, $start_position + 1);
#          if (($start_position >= 0) && ($end_position > $start_position)) {
#            my $value = substr($message, $start_position, $end_position - $start_position);
#            $message = substr($message, $end_position);
#            $rc->{$key} = $value;
#          }
#        }
#      }
      if ($rc) {
        # Komponenten erfolgreich aus Message extrahiert
        Trace->Trc('I', 1, 0x03902, join(' ', %{$rc}));
      }
    } else {
      Trace->Trc('I', 1, 0x0b901, $message);
    }
  } else {
    Trace->Trc('I', 2, 0x0b900);
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub _bindSocket {
  #################################################################
  #     An PubSocket binden
  #     Proc 7
  #     Eingabe:
  #     Ausgabe: O: Socket nicht binded
  #              1: Socket binded
  #
  my $self = shift;
  my %args = (@_);

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  if (!$self->{Status}->{$args{Socket}}) {
    eval {$self->{$args{Socket}}->bind($self->{$args{Addr}})};
    if (!$@) {
      $self->{Status}->{$args{Socket}} = 1;
      Trace->Trc('I', 1, 0x03700, $args{Addr}, $self->{$args{Addr}});
    } else {
      $self->{Status}->{$args{Socket}} = 0;
      Trace->Trc('I', 1, 0x0b700, $args{Addr}, $self->{$args{Addr}}, join(' ', $@));
    }
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $self->{Status}->{PubSock});
  #$self->{subroutine} = $merker;

  return $self->{Status}->{$args{Socket}};
}


#sub getInfo {
#  #################################################################
#  #     Information vom MT4 abfragen
#  #     Proc 2
#  #     Eingabe: Argumenthash mit mindestens einem Element 'cmd'
#  #              mit Elementen: typ:  status|info
#  #                             wert: bridge|tick|account|ema|order
#  #              Mögliche Wert: status   -> bridge
#  #                             info     -> tick
#  #                             info     -> account
#  #                             info     -> ema
#  #                             info     -> order
#  #     Ausgabe: Status der Bridge
#  #
#  my $self = shift;
#  my %args = (@_);
#
#  my $merker          = $self->{subroutine};
#  $self->{subroutine} = (caller(0))[3];
#  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
#  
#  my $rc = undef;
#
#  # Get Data with next Tick
#  $rc = $self->_recv();
##  if (!$@) {
#  if (defined($rc)) {
#    $rc = decode_json($rc);
#    Trace->Trc('I', 1, 0x03200, $args{typ} . '|' . $args{account} . ' ' . $args{wert}, $rc);
#  } else {
#    Trace->Trc('I', 1, 0x0b200, $args{typ} . '|' . $args{account} . ' ' . $args{wert});
#  }  
#
#  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
#  $self->{subroutine} = $merker;
#
#  return $rc;
#}


#sub _send {
#  #################################################################
#  #     An PubSocket binden
#  #     Proc 8
#  #     Eingabe: $1: Kommando
#  #              $2: Flags
#  #     Ausgabe: O: Socket nicht binded
#  #              1: Socket binded
#  #
#  my $self = shift;
#  my $cmd  = shift;
#
#  #my $merker          = $self->{subroutine};
#  #$self->{subroutine} = (caller(0))[3];
#  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
#  
#  my $rc = $self->_bindSocket('Socket', 'PubSock', 'Addr', 'PubAddr');
#
#  if ($rc) {
#    eval {$rc = $self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
#    if ($@) {
#      # Fehler
#      $rc = 0;
#      Trace->Trc('I', 1, 0x0b800, $self->{PubAddr}, join(' ', $@));
#    } else {
#      # Alles ok
#      $rc = 1;
#      Trace->Trc('I', 1, 0x03800, $self->{PubAddr}, join(' ', $@));
#    }
#  }
#  
#  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
#  #$self->{subroutine} = $merker;
#
#  return $rc;
#}


#sub _recv {
#  #################################################################
#  #     SubSocket connecten
#  #     Proc 6
#  #     Eingabe: $1: Flags
#  #     Ausgabe: O: Socket nicht connected
#  #              1: Socket connected
#  #
#  my $self = shift;
#  my %args = (@_);
#
#  #my $merker          = $self->{subroutine};
#  #$self->{subroutine} = (caller(0))[3];
#  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
#
#  my $rc = $self->_bindSocket('Socket', 'RepSock', 'Addr', 'RepAddr');
#
#  if ($rc) {
#    eval {$rc = $self->{RepSock}->recv(ZMQ_DONTWAIT)};
#    if ($@) {
#      # Fehler
#      $rc = undef;
#      Trace->Trc('I', 3, 0x0b600, $self->{RepAddr}, join(' ', $@));
#    } else {
#      # Alles ok
#      Trace->Trc('I', 2, 0x03600, $self->{RepAddr}, join(' ', $@));
#    }
#  }
#  
#  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
#  #$self->{subroutine} = $merker;
#
#  return $rc;
#}


1;
