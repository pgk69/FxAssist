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
use ZMQ::FFI::Constants qw(ZMQ_PUB ZMQ_SUB ZMQ_DONTWAIT ZMQ_SUBSCRIBE ZMQ_NOBLOCK);
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

  # MQL4 Initialisierung
  $self->{JSON}    = JSON::PP->new->utf8;
  
  # ZeroMQ Initialisierung pub/sub
  #### Context
  $self->{Context} = ZMQ::FFI->new();

  ### Subscriber ####
  $self->{SubAddr} = Utils::extendString($args{SubAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{SubSock} = $self->{Context}->socket(ZMQ_SUB);
  $self->{SubSock}->connect($self->{SubAddr});

  ### Publisher ####
  $self->{PubAddr} = Utils::extendString($args{PubAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{PubSock} = $self->{Context}->socket(ZMQ_PUB);
  $self->{PubSock}->bind($self->{PubAddr});
  
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


sub cmd {
  #################################################################
  #     Kommunikation mit dem MT4
  #     Proc 1
  #     Eingabe: Argumenthash mit mindestens den Elementen 
  #              cmd     : Auszuführendes Kommando
  #              account : Betroffenes Konto
  #              uid     : Betroffene UID
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
  #  Kommando get_parameter:
  #  
  #    Request Value: cmd|[account name]|[uid] {"cmd":  "get_parameter",
  #                                             "name": "[abgefragter Wert]"}
  #                   cmd|testaccount|fdjksalr38wufsd= {"cmd":  "set_parameter",
  #                                                     "name": "pair"}
  #                       
  #    Response: [Parameterwert]
  #              EURUSD
  #  
  #  
  #  Kommando set_parameter:
  # 
  #    Request Value: cmd|[account name]|[uid] {"cmd":   "set_parameter",
  #                                             "name":  "[zu setzender Parameter]",
  #                                             "value": "[zu setzender Wert]"}
  #                   cmd|testaccount|fdjksalr38wufsd= {"cmd":   "set_parameter",
  #                                                     "name": ‚ "Wait_for_Message",
  #                                                     "value": "0"}
  #                       
  #    Response: 0: Nicht erfolgreich
  #              1: Erfolgreich
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
  #    Response: Order has been opened:[Ticket ID]
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
  #    Response: Order has been modified:[Ticket ID]
  #
  #
  #  Kommando unset:
  #
  #    Close Trade/Order: cmd|[account name]|[uid] {"cmd":    "unset",
  #                                                 "ticket": "[Ticket ID]"}
  #
  #    Response: Order has been closed:[Ticket ID]
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
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  if (defined($args{cmd})) {
    my $cmd = "cmd|$args{Account}|$args{Uid} ";
    delete($args{Account});
    delete($args{Uid});
    $cmd .= $self->{JSON}->utf8(0)->encode(\%args);

    Trace->Trc('I', 1, 0x03100, $cmd, ZMQ_DONTWAIT);

    eval {$self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
    if (!$@) {
      Trace->Trc('I', 1, 0x03101, $cmd);
      usleep 100_000;
      eval {$rc = $self->{SubSock}->recv(ZMQ_DONTWAIT)};
      if (!$@) {
        # Response:   response|[account name]|[uid] {"response": "[response]"}
        #
        # Responses:  0
        #             1
        #             true
        #             false
        #             Order has been send:[Ticket ID]
        #             Order has been modified.
        #             Order has been closed.
        #             [pair]
        #
        if ($rc =~ /^response\|$args{Account}\|$args{Uid} \{\"response\"\:[\s]*\"([^\"]+)\"\}$/) {
          my $response = $1;
          if      ($args{cmd} eq 'get_parameter') {
            $rc = $response;
          } elsif ($args{cmd} eq 'set_parameter') {
            $rc = $response;
          } elsif ($args{cmd} eq 'set') {
            #    Response: Order has been send:[Ticket ID]
            if ($response =~ /^Order has been send:(.*)$/) {
              $rc = $1;
            }
          } elsif ($args{cmd} eq 'reset') {
            #    Response: Order has been modified.
            $rc = ($response =~ /^Order has been modified:(.*)$/);
          } elsif ($args{cmd} eq 'unset') {
            #    Response: Order has been closed.
            $rc = ($response =~ /^Order has been closed:(.*)$/);
          } elsif ($args{cmd} eq 'draw') {
            #    Response: true|false
            $rc = ($response eq 'true');
          } else {
            # unbekanntes Kommando
            $rc = 0;
          }
        }

        if ($rc) {
          # Operation erfolgreich. Signal ist aktiviert(open) oder deaktiviert(close)
          #$self->{Store}->{Signal}->{$id}->{Activ} = ($op eq 'open');
          Trace->Trc('I', 1, 0x03102, $cmd, $rc);
        } else {
          Trace->Trc('I', 1, 0x0b103, $cmd);
        }
      } else {
        Trace->Trc('I', 1, 0x0b102, $cmd, $rc);
      }
    } else {
      Trace->Trc('I', 1, 0x0b101, $cmd, $rc);
    }
  } else {
    Trace->Trc('I', 1, 0x0b100, join(' ', %args));
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub getInfo {
  #################################################################
  #     Information vom MT4 abfragen
  #     Proc 2
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

  # Subscriber for Infotype
  $self->{SubSock}->subscribe($args{typ} . '|' . $args{Account} . ' ' . $args{wert});
    
  # Get Data with next Tick
  eval {$rc = $self->{SubSock}->recv(ZMQ_DONTWAIT)};
  if (!$@) {
    Trace->Trc('I', 1, 0x03200, $args{typ} . '|' . $args{Account} . ' ' . $args{wert}, $rc);
  } else {
    Trace->Trc('I', 1, 0x0b200, $args{typ} . '|' . $args{Account} . ' ' . $args{wert});
  }  

  # Subscriber for Infotype
  $self->{SubSock}->unsubscribe($args{typ} . '|' . $args{Account} . ' ' . $args{wert});

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub subscribeAccount {
  #################################################################
  #     Kontoinformationen subscriben
  #     Proc 2
  #     Eingabe: Account -> Accountnummer
  #     Ausgabe: O: Account nicht verbunden
  #              1: Account verbunden
  #
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;

  $self->{SubSock}->subscribe("response|" . $args{Account});

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub unsubscribeAccount {
  #################################################################
  #     Kontoinformationen unsubscriben
  #     Proc 2
  #     Eingabe: Account -> Accountnummer
  #     Ausgabe: O: Account nicht verbunden
  #              1: Account verbunden
  #
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;

  $self->{SubSock}->unsubscribe("response|" . $args{Account});

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}



1;
