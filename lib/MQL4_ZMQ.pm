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
use Data::UUID;
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

  # Initialisierung JSON Objekt
  $self->{JSON}    = JSON::PP->new->utf8;
  
  # Initialisierung UUID Objekt
  $self->{UUID}    = Data::UUID->new;
  
  # ZeroMQ Initialisierung pub/sub
  #### Context
  $self->{Context} = ZMQ::FFI->new();

  ### Subscriber ####
  $self->{SubAddr} = Utils::extendString($args{SubAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{SubSock} = $self->{Context}->socket(ZMQ_SUB);
  $self->_connectSocket();
  
  ### Publisher ####
  $self->{PubAddr} = Utils::extendString($args{PubAddr}, "BIN|$Bin|SCRIPT|" . uc($Script));
  $self->{PubSock} = $self->{Context}->socket(ZMQ_PUB);
  $self->_bindSocket();
  
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
  #     Kommandoversand an den MT4
  #     Proc 1
  #     Eingabe: Argumenthash mit mindestens den Elementen 
  #              cmd     : Auszuführendes Kommando
  #              account : Betroffenes Konto
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
  #    Ausgabe: Referenz ID des Kommandos (Unique ID)
  #     
  #    Kommando get_parameter:
  #
  #    Request Value: cmd|[account name] {"cmd":      "get_parameter",
  #                                       "referenz": "[Referenz ID]",
  #                                       "name":     "[abgefragter Wert]"}
  #                   cmd|testaccount {"cmd":      "set_parameter",
  #                                    "referenz": "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                    "name":     "pair"}
  #                       
  #    Erwarteter Response: Get Parameter
  #              account:  [Accountnummer]
  #              referenz: [Referenz ID]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
  #              msg:      "Parameter read [Name]:[Wert]"
  #              name:     [Name]
  #              value:    [Wert]
  #
  #
  #  Kommando set_parameter:
  #
  #    Request Value: cmd|[account name] {"cmd":      "set_parameter",
  #                                       "referenz": "[Referenz ID]",
  #                                       "name":     "[zu setzender Parameter]",
  #                                       "value":    "[zu setzender Wert]"}
  #                   cmd|testaccount {"cmd":      "set_parameter",
  #                                    "referenz": "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                    "name":     "Wait_for_Message",
  #                                    "value":    "0"}
  #                       
  #    Erwarteter Response: Set Parameter 
  #              account:  [Accountnummer]
  #              referenz: [Referenz ID]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
  #              msg:      "Parameter set [Name]:[Value]"
  #              name:     [Name]
  #              value:    [Wert]
  #    
  #
  #  Kommando set:
  #
  #    New Trade/Order: cmd|[account name] {"cmd":          "set",
  #                                         "referenz":     "[Referenz ID]",
  #                                         "type":         "[Orderart]", 
  #                                         "pair":         "[gehandeltes Symbol]", 
  #                                         "open_price":   "[Eröffnungskurs]",
  #                                         "slippage":     "[Slippage]", 
  #                                         "magic_number": "[Magic Number]", 
  #                                         "comment":      "[Kommentar]", 
  #                                         "take_profit":  "[TakeProfit]", 
  #                                         "stop_loss":    "[StoppLoss]", 
  #                                         "signal":       "[Signal ID]", 
  #                                         "lot":          "[Anzahl Lots]"}
  #                     cmd|testaccount {"cmd":          "set",
  #                                      "referenz":     "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                      "type":         "2", 
  #                                      "pair":         "EURUSD", 
  #                                      "open_price":   "1.25", 
  #                                      "slippage":     "0.1", 
  #                                      "magic_number": "11041963", 
  #                                      "comment":      "Opened by FxAssist",  
  #                                      "take_profit":  "1.2503", 
  #                                      "stop_loss":    "1.2450", 
  #                                      "signal":       "1225", 
  #                                      "lot":          "0.5"}
  #  
  #    Trade Types:
  #       0 = (MQL4) OP_BUY       - buying position,
  #       1 = (MQL4) OP_SELL      - selling position,
  #       2 = (MQL4) OP_BUYLIMIT  - buy limit pending position,
  #       3 = (MQL4) OP_SELLLIMIT - sell limit pending position,
  #       4 = (MQL4) OP_BUYSTOP   - buy stop pending position,
  #       5 = (MQL4) OP_SELLSTOP  - sell stop pending position.
  #
  #    Erwarteter Response: Trade set
  #              account:  [Accountnummer]
  #              referenz: [Referenz ID]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
  #              ticket:   [Ticket ID]
  #              msg:      "Order has been set: [Ticket ID]"
  #                
  #  
  #  Kommando reset:
  #   
  #    Update Trade:  cmd|[account name] {"cmd":         "reset",
  #                                       "referenz":    "[Referenz ID]",
  #                                       "ticket":      "[Ticket ID]", 
  #                                       "take_profit": "[TakeProfit]", 
  #                                       "stop_loss":   "[StoppLoss]"}
  #                   cmd|testaccount {"cmd":         "reset",
  #                                    "referenz":    "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                    "ticket":      "43916144", 
  #                                    "take_profit": "1.2515", 
  #                                    "stop_loss":   "1.2502"}
  #    
  #    Update Order neu:  cmd|[account name] {"cmd":         "reset",
  #                                           "ticket":      "[Ticket ID]", 
  #                                           "take_profit": "[TakeProfit]", 
  #                                           "stop_loss":   "[StoppLoss]",
  #                                           "open_price":  "[Eröffnungskurs]"}
  #                       cmd|testaccount {"cmd":         "reset",
  #                                        "referenz":    "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                        "ticket":      "43916144", 
  #                                        "take_profit": "1.2515", 
  #                                        "stop_loss":   "1.2502",
  #                                        "open_price":  "1.2507"}
  #    
  #    Erwarteter Response: Trade reset
  #              account:  [Accountnummer]
  #              referenz: [Referenz ID]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
  #              ticket:   [Ticket ID]
  #              msg:      "Order has been modified: [Ticket ID]"
  #
  #
  #  Kommando unset:
  #
  #    Close Trade/Order: cmd|[account name] {"cmd":      "unset",
  #                                           "referenz": "[Referenz ID]",
  #                                           "ticket":   "[Ticket ID]"}
  #                       cmd|testaccount {"cmd":      "unset",
  #                                        "referenz": "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                        "ticket":   "43916144"}
  #
  #    Erwarteter Response: Trade unset
  #              account:  [Accountnummer]
  #              referenz: [Referenz ID]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
  #              ticket:   [Ticket ID]
  #              msg:      "Order has been closed: [Ticket ID]"
  #     
  #  Kommando draw:
  #
  #    Draw Object:   cmd|[account name] {"cmd":         "draw",
  #                                       "referenz":    "[Referenz ID]",
  #                                       "obj_type":    "[Objekt Type]", 
  #                                       "open_price":  "[Eröffnungskurs]", 
  #                                       "close_price": "[Schlußkurs]",
  #                                       "close_time":  "[Schlußzeit]",
  #                                       "prediction":  "[Prediction]"}
  #                   cmd|testaccount {"cmd":         "draw",
  #                                    "referenz":    "4162F712-1DD2-11B2-B17E-C09EFE1DC403",
  #                                    "object_type": "OBJ_ARROW", 
  #                                    "open_price":  "1.2054", 
  #                                    "close_time":  "753324221",
  #                                    "close_price": "1.2234",
  #                                    "prediction":  "0.7"}
  #
  #    Erwarteter Response: Draw
  #              account:  [Accountnummer]
  #              status:   0: Nicht erfolgreich
  #                        1: Erfolgreich
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  if (defined($args{cmd})) {
    my $cmd = "cmd|$args{account} ";
    delete($args{account});
    # Erzeugen einer eindeutigen Referenz ID
    $args{referenz} = $self->{UUID}->create_str() if (!defined($args{referenz}));
    $cmd .= $self->{JSON}->utf8(0)->encode(\%args);

    Trace->Trc('I', 1, 0x03100, $cmd, ZMQ_DONTWAIT);

#    eval {$self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
#    if (!$@) {
    if ($rc = $self->_send($cmd)) {
      $rc = $args{referenz};
      Trace->Trc('I', 1, 0x03101, $cmd, $rc);
    } else {
      Trace->Trc('I', 1, 0x0b101, $cmd, $rc);
    }
  } else {
    Trace->Trc('I', 1, 0x0b100, join(' ', %args));
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub getResponse {
  #################################################################
  #     Responseabfrage vom MT4
  #     Proc 9
  #     Eingabe: Argumenthash mit den Werten
  #              account : Betroffenes Konto
  #
  #     Ausgabe: Argumenthash mit mindestens den Elementen 
  #              account : Betroffenes Konto
  #              status  : Gesamtergebnis: 0: Nicht erfolgreich
  #                                        1: Erfolgreich
  #
  #              Weitere moegliche Elemente:
  #              referenz : Signal ID
  #              ticket   : Ticket ID 
  #              msg      : Nachrichten Freitext
  #              name     : Parameter Name
  #              value    : abgefragter/zu setzender Wert
  #     
  #  Responses:
  #    Get Parameter:
  #                 response|[account name] {"account":  "[Accountnummer]",
  #                                          "referenz": "[Referenz ID]",
  #                                          "status":   "[0|1]",
  #                                          "msg":      "Parameter read [Name]:[Wert]",
  #                                          "name":     "[abgefragter Parameter]",
  #                                          "value":    "[abgefragter Wert]"}
  #  
  #    Set Parameter:
  #                 response|[account name] {"account":  "[Accountnummer]",
  #                                          "referenz": "[Referenz ID]",
  #                                          "status":   "[0|1]",
  #                                          "msg":      "Parameter read [Name]:[Wert]",
  #                                          "name":     "[zu setzender Parameter]",
  #                                          "value":    "[zu setzender Wert]"}
  #  
  #    Trade set:   response|[account name] {"account":  "[Accountnummer]"
  #                                          "referenz": "[Referenz ID]",
  #                                          "status":   "[0|1]",
  #                                          "ticket":   "[Ticket ID]",
  #                                          "msg":      "Order has been set: [Ticket ID]"}
  #  
  #    Trade reset: response|[account name] {"account":  "[Accountnummer]",
  #                                          "referenz": "[Referenz ID]",
  #                                          "status":   "[0|1]",
  #                                          "ticket":   "[Ticket ID]",
  #                                          "msg":      "Order has been modified: [Ticket ID]"}
  #  
  #    Trade unset: response|[account name] {"account":  "[Accountnummer]",
  #                                          "referenz": "[Referenz ID]",
  #                                          "status":   "[0|1]",
  #                                          "ticket":   "[Ticket ID]",
  #                                          "msg":      "Order has been closed: [Ticket ID]"}
  #  
  #    Draw:        response|[account name] {"account":  "[Accountnummer]",
  #                                          "status":   "[0|1]"}
    
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  # Lese die gesamte Message aus der Queue
  my $message = $self->_recv();
  if ($message) {
    Trace->Trc('I', 2, 0x03900, $message);
    if ($message =~ /^response\|$args{account} \{(.*)\}$/) {
      $message = $1;
      Trace->Trc('I', 2, 0x03901, $message);
      $rc->{account} = $args{account};
      my $start_position = 0;
      my $end_position = length($message);
      while (($start_position >= 0) && ($end_position > $start_position)) {
        $start_position = index('"', $message, 0) + 1;
        $end_position   = index('"', $message, $start_position + 1);
        if (($start_position >= 0) && ($end_position > $start_position)) {
          my $key = lc(substr($message, $start_position, $end_position - $start_position));
          $start_position = index('"', $message, $end_position) + 1;
          $end_position   = index('"', $message, $start_position + 1);
          if (($start_position >= 0) && ($end_position > $start_position)) {
            my $value = substr($message, $start_position, $end_position - $start_position);
            $message = substr($message, $end_position);
            $rc->{$key} = $value;
          }
        }
      }
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
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  # Get Data with next Tick
  $rc = $self->_recv();
#  if (!$@) {
  if (!$rc) {
    Trace->Trc('I', 1, 0x03200, $args{typ} . '|' . $args{account} . ' ' . $args{wert}, $rc);
  } else {
    Trace->Trc('I', 1, 0x0b200, $args{typ} . '|' . $args{account} . ' ' . $args{wert});
  }  

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub subscribeAccount {
  #################################################################
  #     Kontoinformationen subscriben
  #     Proc 3
  #     Eingabe: typ     -> response
  #              Account -> Accountnummer
  #              wert    -> optionaler Wert
  #     Ausgabe: O: Account nicht verbunden
  #              1: Account verbunden
  #
  my $self = shift;
  my %args = (@_);

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  my $subscribestring = $args{typ} . '|' . $args{account};
  if (defined($args{wert})) {
    $subscribestring .= ' ' . $args{wert};
  }
  eval {$self->{SubSock}->subscribe($subscribestring)};
  if (!$@) {
    $rc = 1;
    $self->{Status}->{SubSock} = 1;
    Trace->Trc('I', 1, 0x03300, $self->{PubAddr} . ' ' . $subscribestring, join(' ', $@));
  } else {
    $rc = 0;
    $self->{Status}->{SubSock} = 0;
    Trace->Trc('I', 1, 0x0b300, $self->{PubAddr} . ' ' . $subscribestring, join(' ', $@));
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  #$self->{subroutine} = $merker;

  return $rc;
}


sub unsubscribeAccount {
  #################################################################
  #     Kontoinformationen unsubscriben
  #     Proc 4
  #     Eingabe: typ     -> response
  #              Account -> Accountnummer
  #              wert    -> optionaler Wert
  #     Ausgabe: O: Account nicht verbunden
  #              1: Account verbunden
  #
  my $self = shift;
  my %args = (@_);

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = 0;

  eval {$self->{SubSock}->unsubscribe($args{typ} . '|' . $args{account} . ' ' . $args{wert})};
  if (!$@) {
    $rc = 1;
    $self->{Status}->{SubSock} = 1;
    Trace->Trc('I', 1, 0x03400, $self->{PubAddr} . ' ' . $args{typ} . '|' . $args{account} . ' ' . $args{wert}, join(' ', $@));
  } else {
    $rc = 0;
    $self->{Status}->{SubSock} = 0;
    Trace->Trc('I', 1, 0x0b400, $self->{PubAddr} . ' ' . $args{typ} . '|' . $args{account} . ' ' . $args{wert}, join(' ', $@));
  }

  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  #$self->{subroutine} = $merker;

  return $rc;
}


sub _connectSocket {
  #################################################################
  #     SubSocket connecten
  #     Proc 5
  #     Eingabe:
  #     Ausgabe: O: Socket nicht connected
  #              1: Socket connected
  #
  my $self = shift;
  my %args = (@_);

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  if (!$self->{Status}->{SubSock}) {
    eval {$self->{SubSock}->connect($self->{SubAddr})};
    if (!$@) {
      $self->{Status}->{SubSock} = 1;
      Trace->Trc('I', 1, 0x03500, $self->{SubAddr}, join(' ', $@));
    } else {
      $self->{Status}->{SubSock} = 0;
      Trace->Trc('I', 1, 0x0b500, $self->{SubAddr}, join(' ', $@));
    }
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $self->{Status}->{SubSock});
  #$self->{subroutine} = $merker;

  return $self->{Status}->{SubSock};
}


sub _recv {
  #################################################################
  #     SubSocket connecten
  #     Proc 6
  #     Eingabe: $1: Flags
  #     Ausgabe: O: Socket nicht connected
  #              1: Socket connected
  #
  my $self = shift;
  my %args = (@_);

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = $self->_connectSocket();

  if ($rc) {
    eval {$rc = $self->{SubSock}->recv(ZMQ_DONTWAIT)};
    if ($@) {
      # Fehler
      $rc = 0;
      Trace->Trc('I', 1, 0x0b600, $self->{SubAddr}, join(' ', $@));
    } else {
      # Alles ok
      $rc = 1;
      Trace->Trc('I', 1, 0x03600, $self->{SubAddr}, join(' ', $@));
    }
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  #$self->{subroutine} = $merker;

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
  
  if (!$self->{Status}->{PubSock}) {
    eval {$self->{PubSock}->bind($self->{PubAddr})};
    if (!$@) {
      $self->{Status}->{PubSock} = 1;
      Trace->Trc('I', 1, 0x03700, $self->{PubAddr}, join(' ', $@));
    } else {
      $self->{Status}->{PubSock} = 0;
      Trace->Trc('I', 1, 0x0b700, $self->{PubAddr}, join(' ', $@));
    }
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $self->{Status}->{PubSock});
  #$self->{subroutine} = $merker;

  return $self->{Status}->{PubSock};
}


sub _send {
  #################################################################
  #     An PubSocket binden
  #     Proc 8
  #     Eingabe: $1: Kommando
  #              $2: Flags
  #     Ausgabe: O: Socket nicht binded
  #              1: Socket binded
  #
  my $self = shift;
  my $cmd  = shift;

  #my $merker          = $self->{subroutine};
  #$self->{subroutine} = (caller(0))[3];
  #Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
  
  my $rc = $self->_bindSocket();

  if ($rc) {
    eval {$rc = $self->{PubSock}->send($cmd, ZMQ_DONTWAIT)};
    if ($@) {
      # Fehler
      $rc = 0;
      Trace->Trc('I', 1, 0x0b800, $self->{PubAddr}, join(' ', $@));
    } else {
      # Alles ok
      $rc = 1;
      Trace->Trc('I', 1, 0x03800, $self->{PubAddr}, join(' ', $@));
    }
  }
  
  #Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  #$self->{subroutine} = $merker;

  return $rc;
}




1;
