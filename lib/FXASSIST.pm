package FXASSIST;

#-------------------------------------------------------------------------------------------------
# Letzte Aenderung:     $Date: $
#                       $Revision: $
#                       $Author: $
#
# Aufgabe:		- Ausfuehrbarer Code von fxassist.pl
#
# Done Implentierung cronaehnlicher Aktivitaetssteuerung (Schedule::Cron?)
# ToDo Storables zun Laufen bringen falls moeglich
# ToDo Ggf. LWP::RobotUA einsetzen
# ToDo ZMQ::LibZMQ2 Fehler cpanm install fixen Alternativ: LibZMQ3 oder LibZMQ4 Library fuer MT4
# ToDo ZeroMQ Telegramme definieren und auf beiden Seiten (Perl und MT4) implementieren
# ToDo Nach Abbruch der Internetverbindung: Use of uninitialized value in pattern match (m//) at /Users/pgk/Documents/00_Eclipse/FxAssist/lib/FXASSIST.pm line 431.
#      if (defined($self->{Response}) &&
#          $self->{Response}->is_success() &&
#          $self->{Response}->header('title') =~ /$self->{Location}->{Login}->{Title}/ &&
#          $self->{Response}->content() =~ m/form[^>]*name="$self->{Location}->{Login}->{Form}->{Name}"/ &&
#          $self->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
# ToDo Ergebnis des ZMQ Transfers ermitteln (kein Returncode verfuegbar) 
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

use Trace;
use CmdLine;
use Configuration;
use Utils;

use MQL4_ZMQ;

#
# Module
#
use FindBin qw($Bin $Script $RealBin $RealScript);
use LockFile::Simple qw(lock trylock unlock);
use LWP;
use HTTP::Cookies;

use HTML::Entities;
use utf8;
use Data::UUID;
use Text::Unidecode;

#
# Konstantendefinition
#

#
# Variablendefinition
#
my $countloop = 0;

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
  
  my %cfg = Configuration->config();
  
  # Ggf. Plugins laden falls in der Ini etwas angegeben ist
  if ($cfg{Prg}{Plugin}) {
    # refs ausschalten wg. dyn. Proceduren
    no strict 'refs';
    my %plugin = ();

    # Bearbeiten aller Erweiterungsmodule die in der INI-Datei
    # in Sektion [Prg] unter "Plugin =" definiert sind
    foreach (split(/ /, $cfg{Prg}{Plugin})) {
      # Falls ein Modul existiert
      if (-e "$Bin/plugins/${_}.pm") {

        # Einbinden des Moduls
        require $_ . '.pm';
        $_->import();

        # Initialisieren des Moduls, falls es eine eigene Sektion
        # [<Modulname>] fuer das Module in der INI-Datei gibt
        $plugin{$_} = eval {$_->new(Configuration->config('Plugin ' . $_))};
        eval {
          $plugin{$_} ? $plugin{$_}->DESTROY : ($_ . '::DESTROY')->()
            if (CmdLine->option('erase'));
        };
      }
    }
    use strict;
  }

  # Module::Refresh->refresh;
  
  # Test der benoetigten INI-Variablen
  # DB-Zugriff

  # Test der Komandozeilenparameter
  if (CmdLine->option('Help') || CmdLine->option('Version')) {
    CmdLine->usage();
    if (CmdLine->option('Help') || CmdLine->option('Version')) {
      Trace->Exit(0, 1, 0x00002, Configuration->prg, $VERSION);
    }
    Trace->Exit(1, 0, 0x08000, join(" ", CmdLine->argument()));
  }
  
  # Einmalige oder parallele Ausführung
  if ($cfg{Prg}{LockFile}) {
    $self->{LockFile} = File::Spec->canonpath(Utils::extendString($cfg{Prg}{LockFile}, "BIN|$Bin|SCRIPT|" . uc($Script)));
    $self->{Lock} = LockFile::Simple->make(-max => 5, -delay => 1, -format => '%f', -autoclean => 1, -stale => 1, -wfunc => undef);
    my $errtxt;
    $SIG{'__WARN__'} = sub {$errtxt = $_[0]};
    my $lockerg = $self->{Lock}->trylock($self->{LockFile});
    undef($SIG{'__WARN__'});
    if (defined($errtxt)) {
      $errtxt =~ s/^(.*) .+ .+ line [0-9]+.*$/$1/;
      chomp($errtxt);
      Trace->Trc('S', 1, 0x00012, $errtxt) if defined($errtxt);
    }
    if (!$lockerg) {
      Trace->Exit(0, 1, 0x00013, Configuration->prg, $self->{LockFile})
    } else {
      Trace->Trc('S', 1, 0x00014, $self->{LockFile})
    }
  }
  
  # Initialisierung UUID Objekt
  $self->{UUID} = Data::UUID->new();
  
  # Anlegen der ZMQ Verbindung
  $self->{ZMQ} = MQL4_ZMQ->new('PubAddr' => $cfg{ZMQ}{PubAddr} || '5555',
                               'RepAddr' => $cfg{ZMQ}{RepAddr} || '5556');

  # Einlesen aller konfigurierten Kontoverbindungen
  # Nicht mehr noetig, wird in syncAccount erledigt
#  foreach my $section (keys %cfg) {
#    next unless $section =~ /^Account (.*)$/;
#    my $account = $1;
#    while ((my $key, my $value) = each(%{$cfg{$section}})) {
#      $self->{Account}->{$account}->{$key} = Utils::extendString($value);
#    }
#    if (defined($account) && 
#        defined($self->{Account}->{$account}->{MagicNumber}) &&
#        defined($self->{Account}->{$account}->{Symbol})) {
#      # Status: 0: nicht connected
#      #         1: connected aber nicht gesynct
#      #         2: connected syncing laeuft
#      #         3: connected und gesynct
#      $self->{Account}->{$account}->{Status} = 0;
#    } else {
#      delete($self->{Account}->{$account});
#    }
#  }
   
  # Mit dem RobotUA wird das Warten automatisiert; leider kommen wir damit nicht rein
  # $self->{Browser} = LWP::RobotUA->new('Me/1.0', 'a@b.c');
  # $self->{Browser}->delay(60/60);  # avoid polling more often than every 1 minute
  $self->{Browser} = LWP::UserAgent->new( );
  $self->{Browser}->env_proxy();   # if we're behind a firewall
  
  # Falls Cookies defiiniert sind werden die Cookies geladen (entweder Datei oder Memorycookies)
  if ($cfg{Prg}{Cookie}) {
    $self->{Cookie} = Utils::extendString($cfg{Prg}{Cookie}, "BIN|$Bin|SCRIPT|" . uc($Script));
    if ($self->{Cookie} eq '1') {
      $self->{Browser}->cookie_jar({});
    } else {
      $self->{Browser}->cookie_jar(HTTP::Cookies->new('file'     => $self->{Cookie},
                                                      'autosave' => 1));
    }
  }

  # Falls ein Aktivitaetszeitraum konfiguriert ist wird er gesetzt
  $self->{Cron}          = $cfg{Prg}{Aktiv} | '* * * * * 0-59/5';
  $self->{NextExecution} = Schedule::Cron->get_next_execution_time($self->{Cron});
  
  # URL-Zugriff, Form- und Datenfelder definieren
  if (!defined($self->{Location})) {
    foreach my $section (keys %cfg) {
      next unless $section =~ /^Location (.*)$/;
      my $location = $1;
      while ((my $key, my $value) = each(%{$cfg{$section}})) {
        (my $key1, my $value1) = split(' ', $key);
        if (defined($value1)) {
          $self->{Location}->{$location}->{$key1}->{$value1} = Utils::extendString($value);
        } else {
          $self->{Location}->{$location}->{$key} = Utils::extendString($value);
        }
      }
    }
    $self->{Location}->{Last}       = '';
    $self->{Location}->{Next}       = 'Login';
    $self->{Location}->{Delay}      = 0;
    $self->{Location}->{Lazyfaktor} = $cfg{Prg}{Lazyfaktor} || 10;
  }
  
  $self->{SignalAktuell}->{ID}   = 0;
  $self->{SignalAktuell}->{UUID} = 0;

  Trace->Exit(1, 0, 0x08002, 'Location') if (!defined($self->{Location}));
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
  }
  for my $parent (@ISA) {
    if ( my $coderef = $self->can( $parent . "::DESTROY" ) ) {
      $self->$coderef();
    }
  }
  # Eigentlich nicht noetig, da -autoclean => 1
  if ($self->{Lock}) {$self->{Lock}->unlock($self->{LockFile})}
}


sub EAKommunikation {
  #################################################################
  #     Procedure zur Uebergabe von Kommandos und Abholen des 
  #     Status von den angemeldeten EAs
  #     Proc 5
  #
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine});
  
  my $rc = 0;
  
  # Einlesen von der Schnittstelle und Auswerten der gelesenen Signale
  # Falls es einen Grund gibt, warum wir nochmal einlesen sollten, merken wir uns das
  my $do_EA_IO = $self->readMessage(0);

  # Ausfuehren der EA-IO
  # Ein Signal hat 2 Flags. In Abhaengigkeit von diesen sind  
  # unterschiedliche Instruktionen zu geben
  # Aktiv  Valid  Instruktion
  #   1      0    Sende Schliessauftrag fuer diese Postition
  #   1      1    -
  #   0      1    Sende Eroeffnungsauftrag fuer diese Position
  #   0      0    Das Signal ist erledigt und wird aus der Datenstruktur entfernt
  #               Falls das Signal fuer keinen Account mehr aktiv ist wird es geloescht
  #               Die Auswertung passiert mittels $deleteSignal
  if (defined($self->{Signal})) {
    foreach my $uuid (keys(%{$self->{Signal}})) {
      $self->{Signal}->{$uuid}->{Activ} = 0;
      # Abarbeitung aller bestehenden Signale
      if (defined($self->{Signal}->{$uuid})) {
        $self->doDebugSignal($uuid) if Trace->debugLevel() > 3;
        $do_EA_IO ||= $self->processSignal($uuid);
      }
    }
    
    # Bereinigen der Datenstruktur
    foreach my $uuid (keys(%{$self->{Signal}})) {
      if (!$self->{Signal}->{$uuid}->{Valid} && !$self->{Signal}->{$uuid}->{Activ}) {
        delete($self->{Signal}->{$uuid});
      }
    }
    
    # Es hat eine IO zum EA stattgefunden daher warten wir eine Sekunde und 
    # lesen nochmal den Response
    $self->readMessage(1) if ($do_EA_IO);
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub readMessage {
  #################################################################
  #     Procedure zum Einlesen der EA Response
  my $self = shift;

  # my $merker          = $self->{subroutine};
  # $self->{subroutine} = (caller(0))[3];
  # Trace->Trc('S', 3, 0x00001, $self->{subroutine});
  
  my $rc = 0;

  sleep(shift);
  while (my $msg = ($self->{ZMQ}->readMT4())) {
    # Hashref mit  account : Betroffenes Konto
    #              msgtype : response|bridge|tick|account|ema|orders
    #
    #              uuid:     [UUID]
    #              cmd:      Original Kommando
    #              status  : Gesamtergebnis: 0: Nicht erfolgreich
    #                                        1: Erfolgreich
    #
    #              Weitere moegliche Elemente:
    #              ticket   : Ticket ID 
    #              msg      : Nachrichten Freitext
    #              name     : Parameter Name
    #              value    : abgefragter/zu setzender Wert}
    my $account = $msg->{account};
    if (defined($self->{Account}->{$account})) {
      my $msgtype = $msg->{msgtype};
      my $status  = $msg->{status};
      if ($msgtype eq 'response') {
        # Wir interessieren uns hier nur auf ticketbezogene
        # Responses auf die Kommandos set und unset
        if (my $ticket = $msg->{ticket}) {
          my $uuid    = $msg->{uuid};
          my $cmd     = $msg->{cmd};
          if (defined($self->{Account}->{$account}) &&
              defined($self->{Account}->{$account}->{Signal}->{$uuid})) {
            if ($cmd eq 'set')   {$self->{Account}->{$account}->{Signal}->{$uuid}->{Activ} = $status}
            if ($cmd eq 'unset') {$self->{Account}->{$account}->{Signal}->{$uuid}->{Activ} = $status}
            $self->{Account}->{$account}->{Signal}->{$uuid}->{Ticket} = $ticket;  
          }
        }
      } elsif ($msgtype eq 'bridge') {
        if ($status eq 'up') {
          $self->syncAccount('Account', $account, 
                             'Status',  1);
          $rc = 1;
        }
        if ($status eq 'down') {
          delete($self->{Account}->{$account})
        }
      } elsif ($msgtype eq 'orders') {
        $self->syncAccount('Account', $account, 
                           'Status',  2,
                           'Info',    $msg->{order});
      } elsif ($msgtype eq 'account') {
      } elsif ($msgtype eq 'tick') {
      } elsif ($msgtype eq 'ema') {
      }
    }
  }
  # Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  # $self->{subroutine} = $merker;
}

 
sub syncAccount {
  #################################################################
  #     Ein neuer Account ist aufgetaucht oder ein bekannter muß
  #     neu synchronisiert werden.
  #     Die Prozedur loescht die interen Datenstruktur des Accounts
  #     holt die Infos des Account inkl. der offenen Orders neu ein
  #     und legt die interne Datenstruktur neu an
  #     Accounts werden nur akzeptiert, wenn sie in der INI-Datei
  #     konfiguriert sind.
  #     Einbindung mit if ($self->{Account}->{$args{Account}}{Status} < 3) {syncAccount}
  #     Proc 9
  #     Eingabe: Account -> Accountnummer
  #              Status  -> Account Status: 0 : neu
  #                                         1 : verbunden
  #                                         2 : Synchronisierung gestartet
  #                                         3 : Synchronisierung abgeschlossen
  #              Info    -> Infohash (optional)
  #     Ausgabe: Account Status
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));

  my $rc = -1;

  my %accountdata;
  if ($args{Status} >= 3) {
    # Wir sind schon komplett, falls Infodaten mitkamen schalten wir diese sicherheitshalber
    # nochmal ab
    if (defined($args{Info})) {
      # Orderlistenanforderung ausschalten
      $self->{ZMQ}->sendMT4('account', $args{account},
                            'cmd',     'set_parameter',
                            'name',    'unset_info',
                            'value',   'orders');
    }
    $rc = 3;
  } elsif ($args{Status} == 2) {
    # Synchronisierungsdaten auswerten
#   # Lesen der aktuellen Orders
#   my $orderinfo   = $self->{ZMQ}->getInfo('account', $args{account},
#                                           'typ',     'info',   
#                                           'wert',    'order');

    # my $statusinfo  = $self->{ZMQ}->getInfo('account', $args{account},
    #                                         'typ',    'status',
    #                                         'wert',   'bridge');
    # my $accountinfo = $self->{ZMQ}->getInfo('account', $args{account},
    #                                         'typ',     'info',   
    #                                         'wert',    'account');
    # my $emainfo     = $self->{ZMQ}->getInfo('account', $args{account},
    #                                         'typ',     'info',   
    #                                         'wert',    'ema');

    if (my $orderinfo = $args{Info}) {
      $self->{Account}->{$args{Account}}->{Status} = 3;
      my @orders = @{$orderinfo->{'order'}};
      if ($#orders) {
        # Orders vorhanden -> Einlesen
        $rc = 3;
        foreach my $order (@orders) {
          my %orderattribute;
          while ((my $key, my $value) = each(%{$order})) {
            $orderattribute{$key} = $value;
          }
          # Verfuegbare Attribute
          # ticket     magic_number  type  pair     open_price  take_profit
          # stop_loss  profit        lot   comment  open_time   expire_time
          if (defined($orderattribute{comment}) && $orderattribute{comment} =~ /(.*):FxAssist:ST/) {
            # Nur die eigenen werden bearbeitet
            $self->{Account}->{$args{account}}->{Signal}->{$1}->{Activ}  = 1;
            $self->{Account}->{$args{account}}->{Signal}->{$1}->{UUID}   = $1;
            $self->{Account}->{$args{account}}->{Signal}->{$1}->{Ticket} = $orderattribute{ticket};
            $self->{Account}->{$args{account}}->{Signal}->{$1}->{SL}     = $orderattribute{stop_loss};
            $self->{Account}->{$args{account}}->{Signal}->{$1}->{TP}     = $orderattribute{take_profit};
            # Orderlistenanforderung ausschalten
            $self->{ZMQ}->sendMT4('account', $args{account},
                                  'cmd',     'set_parameter',
                                  'name',    'unset_info',
                                  'value',   'orders');
          } else {
            Trace->Trc('I', 1, 0x02900, $args{Account}, $orderattribute{ticket}, $orderattribute{comment});
          }
        }
      } else {
        # Keine Orders vorhanden
        $rc = -1;
      }
    } else {
      # Aktuelle Orderliste anfordern
      $self->{ZMQ}->sendMT4('account', $args{account},
                            'cmd',     'set_parameter',
                            'name',    'set_info',
                            'value',   'orders');
      $rc = 2;
    }
  } elsif ($args{Status} < 2) {
    # Neuer Account oder Neuinitialisierung
    $accountdata{MagicNumber} = Configuration->config("Account $args{Account}", 'MagicNumber');
    $accountdata{Symbol}      = Configuration->config("Account $args{Account}", 'Symbol');
    $accountdata{Status}      = $rc = 2;
    $self->{Account}->{$args{Account}} = \%accountdata;
    # Aktuelle Orderliste anfordern
    $self->{ZMQ}->sendMT4('account', $args{account},
                          'cmd',     'set_parameter',
                          'name',    'unset_info',
                          'value',   'bridge');
    $self->{ZMQ}->sendMT4('account', $args{account},
                          'cmd',     'set_parameter',
                          'name',    'set_info',
                          'value',   'orders');
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, "$args{Account} $rc");
  $self->{subroutine} = $merker;

  return $rc;
}


sub processSignal {
  #################################################################
  #     Procedure zum Einlesen der EA Response
  my $self = shift;
  my $uuid = shift;

  # my $merker          = $self->{subroutine};
  # $self->{subroutine} = (caller(0))[3];
  # Trace->Trc('S', 3, 0x00001, $self->{subroutine});
  
  my $rc = 0;

  foreach my $account (keys(%{$self->{Account}})) {
    next if ($self->{Account}->{$account}->{Status} < 3);
    if ($self->{Account}->{$account}->{Signal}->{$uuid}->{Activ}) {
      # Signal fuer diesen Account aktiv -> nicht loeschen
      $self->{Signal}->{$uuid}->{Activ} = 1;
      if (!$self->{Signal}->{$uuid}->{Valid}) {
        # Signal nicht valide aber fuer diesen Account noch aktiv -> Trade schliessen
        # EA muß anhande der $uuid sicherstellen, dass doppelte Schliessungen kein Problem darstellen
        $rc = 1;
        $self->{ZMQ}->sendMT4('account',      $account,
                              'uuid',         $uuid,
                              'cmd',          'unset',
                              'ticket',       $self->{Account}->{$account}->{Signal}->{$uuid}->{Ticket});
      }
    } else {
      # Signal fuer diesen Account nicht aktiv
      if ($self->{Signal}->{$uuid}->{Valid}) {
        # Signal valide -> Trade eroeffnen
        # EA muß anhande der $uuid sicherstellen, dass keine Trades doppelt geoeffnet werden
        $rc = 1;
        my $orderart;
        if ($self->{Signal}->{$uuid}->{Signal} =~ /Long$/)  {$orderart = 0}
        if ($self->{Signal}->{$uuid}->{Signal} =~ /Short$/) {$orderart = 1}
        $self->{ZMQ}->sendMT4('account',      $account,
                              'uuid',         $uuid,
                              'cmd',          'set',
                              'type',         $orderart, 
                              'pair',         $self->{Account}->{$account}->{Symbol}, 
                              'magic_number', $self->{Account}->{$account}->{MagicNumber}, 
                              'comment',      $uuid . ':FxAssist:ST',
                              'signal',       $self->{Signal}->{$uuid}->{ID},
                              'lot',          '0.5');
      } else {
        # Signal nicht valide und fuer diesen Account nicht aktiv -> Signal fuer diesen Account loeschen
        delete($self->{Account}->{$account}->{Signal}->{$uuid});
      }  
    }
  }

  # Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  # $self->{subroutine} = $merker;

  return $rc;
}

 
sub getSignals {
  #################################################################
  #     Dauerlaufroutine
  #     Proc 5
  #
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine});
  
  my $rc = 0;
  
  # Falls ein Aktivitaetszeitraum gesetzt ist und wir uns nicht innerhalb befinden
  # machen wir nichts und verlassen die Routinw wieder um mit der EA-Kommunikation
  # weiter zu machen
  if ($self->{NextExecution} < time) {
    $self->{NextExecution} = Schedule::Cron->get_next_execution_time($self->{Cron});
    if (Configuration->config('Prg', 'Fake')) {
      if (!defined($self->{SignalAktuell}->{UUID})) {
        $self->{SignalAktuell}->{UUID}  = $self->{UUID}->create_str();
        $self->{SignalAktuell}->{ID}    = '1234';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Valid}  = 1;
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Activ}  = 0;
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{ID}     = '1497';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Signal} = 'DAX Short';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Stand}  = '9427';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Zeit}   = '20.11.2014 – 09:45 Uhr';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{SL}     = '9455';
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{TP}     = '9399';
      }
    } else {
      if ($self->{Location}->{Next} eq 'Login')  {$self->doLogin()}
      if ($self->{Location}->{Next} eq 'GetIn')  {$self->doGetIn()}
      if ($self->{Location}->{Next} eq 'GetOut') {$self->doGetOut()}
    }
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub doLogin {
  #################################################################
  #     Einloggen
  #     Proc 6
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine});

  my $rc = 0;

  # Holen der Login-Seite
  Trace->Trc('I', 1, 0x02600);
  $self->myGet('Login');
  $self->{Location}->{Last} = 'Login';

  # Auswerten des Response und bei Erfolg Einloggen (Form ausfuellen und abschicken)
  if (defined($self->{Response}) &&
      $self->{Response}->is_success() &&
      $self->{Response}->header('title') =~ /$self->{Location}->{Login}->{Title}/ &&
      $self->{Response}->content() =~ m/form[^>]*name="$self->{Location}->{Login}->{Form}->{Name}"/ &&
      $self->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
    my $action = $1;
    Trace->Trc('I', 4, 0x02601, $self->{Response}->status_line());
    my %formvalues;
    while ((my $key, my $value) = each(%{$self->{Location}->{Login}->{Form}})) {
      next if ($key eq "Name");
      $formvalues{$key} = Utils::extendString($value, , "URL|$self->{Location}->{Login}->{URL}");
    }
    # Einloggen
#   $self->myPost($action, [%formvalues]);
#   my $resp = $self->{Browser}->post($action, [%formvalues]);
#   $self->{Response} = $resp;
    $self->{Response} = $self->{Browser}->post($action, [%formvalues]);
    # Ggf. Redirection folgen
    while ($self->{Response}->is_redirect) {
      $self->{Response} = $self->{Browser}->get($self->{Response}->header('location'));
    }
    $self->doDebugResponse($action, [%formvalues]) if Trace->debugLevel() > 3;
    
    # Auswerten den Einlog Responses und bei Erfolg Weiterschalten der Location auf GetIn
    if ($self->{Response}->is_success &&
       ($self->{Response}->header('title') =~ /$self->{Location}->{$self->{Location}->{Login}->{Next}}->{Title}/)) {
      Trace->Trc('I', 1, 0x02602, $self->{Response}->status_line(), $self->{Location}->{Login}->{Next});
      $self->{Location}->{Next} = $self->{Location}->{Login}->{Next};
      $rc = 1;    
    }
  } else {
    if (defined($self->{Response}) && !$self->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a600, $self->{Response}->status_line(), 'Login'); 
    }
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub myGet {
  #################################################################
  #     URL holen
  #     Proc 3
  # Parameters: the URL,
  #  and then, optionally, any header lines: (key,value, key,value)
  my $self = shift;
  my $type = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, $type);

  my $url = $type;
  if (defined($self->{Location}->{$type})) {
    # Delay noetig, falls kein Redirect oder Statusabfrage
    $url = $self->{Location}->{$type}->{URL};
    my $delay = $self->{Location}->{$type}->{Delay} || 60;
    if (defined($self->{Signal}) && 
        defined($self->{SignalAktuell}) &&
        defined($self->{SignalAktuell}->{UUID}) &&
        defined($self->{Signal}->{$self->{SignalAktuell}->{UUID}}) &&
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Valid}) {
      # Falls das Signal noch gueltig ist werden wir lazy
      $delay = 10 * $self->{Location}->{Lazyfaktor};
    }
    while (time() - $self->{Location}->{Delay} < $delay) {
      Trace->Trc('I', 4, 0x02300, time() - $self->{Location}->{Delay}, $delay);
      sleep $delay - (time() - $self->{Location}->{Delay});
    }
    Trace->Trc('I', 4, 0x02301, time() - $self->{Location}->{Delay}, $delay);
    $self->{Location}->{Delay} = time();
  }
  $self->{Response} = $self->{Browser}->get($url, @_);
  # Ggf. Redirection folgen
  while ($self->{Response}->is_redirect) {
    $self->{Response} = $self->{Browser}->get($self->{Response}->header('location'));
  }
  $self->doDebugResponse($url, @_) if Trace->debugLevel() > 3;
  
  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub doGetIn {
  #################################################################
  #     Datenabruf
  #     Proc 7
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine});
  
  my $rc = 0;

  # Ermitteln des aktuellen Wertes
  if ($self->{Location}->{Last} eq 'Login') {
    # Seite wurde bereits im Rahmen des Login geholt, daher kein erneutes Laden,
    # falls wir von der Location Login kommen
    Trace->Trc('I', 4, 0x02700, $self->{Location}->{Last} || 'Neustart', 'GetIn');
    $self->{Location}->{Last} = 'GetIn';
  } else {
    Trace->Trc('I', 2, 0x02701);
    $self->myGet('GetIn');
  }

  # Holen der Seite erfolgreich ?  
  if (defined($self->{Response}) &&
      $self->{Response}->is_success && 
      $self->{Response}->header('title') =~ /$self->{Location}->{GetIn}->{Title}/) {
    Trace->Trc('I', 1, 0x02702, $self->{Response}->status_line(), 'GetIn');
 
    # Auswertung der Daten
    my %signal;
    my $content = $self->{Response}->decoded_content();
    open IN, '<', \$content or die $!;
    while (<IN>) {
      my $line = $_;
      while ((my $key, my $value) = each(%{$self->{Location}->{GetIn}->{Field}})) {
        if ($line =~ /$value/) {
          $signal{$key} = decode_entities($1);
          $signal{$key} =~ s/([^[:ascii:]]+)/unidecode($1)/ge;
        };
      }
    }
    close(IN);

    if (defined($signal{ID}) && $signal{ID} && 
        ($self->{SignalAktuell}->{ID} ne $signal{ID})) {
      # Neues Signal
      $signal{UUID} = $self->{UUID}->create_str();
      Trace->Trc('I', 1, 0x02703, $signal{ID}, $signal{UUID});
      undef($self->{Signal}->{$signal{UUID}});
      # Neues Signal vorhanden. Altes Signal ist damit ungueltig
      if ($self->{SignalAktuell}->{UUID}) {
        $self->{Signal}->{$self->{SignalAktuell}->{UUID}}->{Valid} = 0;
      }
      $self->{SignalAktuell}->{UUID} = $signal{UUID};
      $self->{SignalAktuell}->{ID}   = $signal{ID};
      $self->{Signal}->{$signal{UUID}}->{Valid} = 1;
      $self->{Signal}->{$signal{UUID}}->{Activ} = 0;
      while ((my $key, my $value) = each %signal) {$self->{Signal}->{$signal{UUID}}->{$key} = $value}  
    }
    $self->doDebugSignal($signal{ID}) if Trace->debugLevel() > 3;
    
    if (defined($self->{Signal}->{$signal{UUID}})) {
      # Holen des Signals erfolgreich: Weiter mit Checken der Historienseite
      $self->{Location}->{Next} = 'GetOut';
    }
  } else {
    # Holen der Werte nicht erfolgreich: Weiterschalten mit Login
    if (defined($self->{Response}) && !$self->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a700, $self->{Response}->status_line(), 'Login'); 
    }
    $self->{Location}->{Next} = 'Login';
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub doGetOut {
  #################################################################
  #     Datenabruf
  #     Proc 8
  # Es kann vorkommen, das wir den Ausstieg nicht erreicht haben.
  # Dies muß dann unmittelbar nachgeholt werden.
  # Der Ausstieg ist erreicht falls
  #   - diese Seite existiert oder
  #   - die aktuelle Signal-ID höher ist als unsere (wird in doGetIn entschieden)
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine});
  
  my $rc = 0;

  $self->{Location}->{Last} = 'GetOut';
  
  if (defined($self->{Signal})) {
    foreach my $uuid (keys(%{$self->{Signal}})) {
      if (defined($self->{Signal}->{$uuid}) && (ref($self->{Signal}->{$uuid}) eq 'HASH')) {      
        $self->doDebugSignal($uuid) if Trace->debugLevel() > 3;
        next unless ($self->{Signal}->{$uuid}->{Valid});
        my $zeit = $self->{Signal}->{$uuid}->{Zeit};
        if ($zeit =~ /([0-9]{2})\.([0-9]{2})\.([0-9]{4})/) {
          my ($d, $m, $j) = ($1, $2, $3);
          my $id = $self->{Signal}->{$uuid}->{ID};
          my $url = Utils::extendString($self->{Location}->{GetOut}->{URL}, "UUID|$uuid|ID|$id|DAY|$d|MONTH|$m|YEAR|$j");
          Trace->Trc('I', 2, 0x02800, $self->{Signal}->{$uuid}->{ID}, $uuid);
          $self->myGet($url);
          if (defined($self->{Response})) {
            Trace->Trc('I', 1, 0x02801, $self->{Response}->status_line(), $uuid);
            # Historieneintrag vorhanden. Signal ist damit ungueltig
            $self->{Signal}->{$uuid}->{Valid} = 0;
          } else {
            Trace->Trc('I', 4, 0x02802, $self->{Response}->status_line(), $uuid);
          }
        }
      }
    }
  }
  Trace->Trc('I', 4, 0x02803, 'GetIn');
  # Unabhaengig vom Ergebnis des Check weitermachen mit der Ermittelung des aktuellen Wertes
  $self->{Location}->{Next} = 'GetIn';

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub doDebugResponse {
  #################################################################
  #     Infos des Respondes ausgeben.
  #     Proc 1
  my $self  = shift;
  my $url   = shift;
  my $param = join('|', @_);
  
  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, "$url $param");

  my $rc = 0;

  Trace->Trc('I', 4, 0x02100, 'URL',                  $url . $param);
  Trace->Trc('I', 4, 0x02100, 'Status',               defined($self->{Response}) ? $self->{Response}->status_line() : '-');
  Trace->Trc('I', 4, 0x02100, 'Title',                defined($self->{Response}) ? $self->{Response}->header('title') : 'Response nicht definiert.');
  Trace->Trc('I', 4, 0x02100, 'Success',              defined($self->{Response}) ? $self->{Response}->is_success() ? 'yes' : 'no'  : '-');
  Trace->Trc('I', 4, 0x02100, 'Redirection',          defined($self->{Response}) ? $self->{Response}->is_redirect() ? 'yes' : 'no' : '-');
  Trace->Trc('I', 4, 0x02100, 'Header',               defined($self->{Response}) ? $self->{Response}->headers_as_string() : '-');
  Trace->Trc('I', 4, 0x02100, 'Document valid until', defined($self->{Response}) ? scalar(localtime($self->{Response}->fresh_until())) : '-');
  my ($form, $action);
  if (defined($self->{Response})) {
    if ($self->{Response}->content() =~ m/form[^>]*name="($self->{Location}->{Login}->{Form}->{Name})"/) {$form = $1};  
    if ($self->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {$action = $1};
  }
  Trace->Trc('I', 4, 0x02100, 'Form',   defined($form) ? $form : '-');
  Trace->Trc('I', 4, 0x02100, 'Action', defined($action) ? $action : '-');
  Trace->Trc('I', 5, 0x02100, 'Content', defined($self->{Response}) ? $self->{Response}->decoded_content() : '-');

  Trace->Trc('S', 3, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub doDebugSignal {
  #################################################################
  #     Infos des Signals ausgeben.
  #     Proc 2
  my $self = shift;
  my $uuid = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, $uuid);

  my $rc = 0;

  Trace->Trc('I', 1, 0x02200, "  Aktuell ID:       ", $self->{SignalAktuell}->{ID});
  Trace->Trc('I', 1, 0x02200, "  Aktuell UUID:     ", $self->{SignalAktuell}->{UUID});
  Trace->Trc('I', 1, 0x02200, "  ID:               ", $self->{Signal}->{$uuid}->{ID});
  Trace->Trc('I', 1, 0x02200, "  UUID:             ", $uuid);
  my $signaldefiniert = defined($self->{Signal}->{$uuid});
  Trace->Trc('I', 1, 0x02200, "  Signal definiert: ", $signaldefiniert ? 'Ja' : 'Nein -> Altes Signal');
  if ($signaldefiniert) {
    Trace->Trc('I', 1, 0x02200, "  Gueltig:          ", $self->{Signal}->{$uuid}->{Valid} ? 'Ja' : 'Nein');
    Trace->Trc('I', 1, 0x02200, "  Aktiv:            ", $self->{Signal}->{$uuid}->{Activ} ? 'Ja' : 'Nein');
    Trace->Trc('I', 1, 0x02200, "  Signal:           ", $self->{Signal}->{$uuid}->{Signal});
    Trace->Trc('I', 1, 0x02200, "  Stand:            ", $self->{Signal}->{$uuid}->{Stand});
    Trace->Trc('I', 1, 0x02200, "  Zeit:             ", $self->{Signal}->{$uuid}->{Zeit});
    Trace->Trc('I', 1, 0x02200, "  Stopp-Loss-Marke: ", $self->{Signal}->{$uuid}->{SL});
    Trace->Trc('I', 1, 0x02200, "  Take-Profit_Marke:", $self->{Signal}->{$uuid}->{TP});
  }

  Trace->Trc('S', 3, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


#sub myPost {
#  #################################################################
#  #     Formular absenden 
#  #     Proc 4
#  # Parameters:
#  #  the URL,
#  #  an arrayref or hashref for the key/value pairs,
#  #  and then, optionally, any header lines: (key,value, key,value)
#  my $self = shift;
#
#  my $merker          = $self->{subroutine};
#  $self->{subroutine} = (caller(0))[3];
#  Trace->Trc('S', 3, 0x00001, $self->{subroutine});
#
#  my $resp = $self->{Browser}->post(@_);
#  $self->{Response} = $resp;
#  # Ggf. Redirection folgen
#  while ($self->{Response}->is_redirect) {
#    $self->{Response} = $self->{Browser}->get($self->{Response}->header('location'));
#  }
#  $self->doDebugResponse(@_) if Trace->debugLevel() > 3;
#
#  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
#  $self->{subroutine} = $merker;
#
#  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
#  #return unless $resp->is_success;
#  #return $resp->content;
#}


#sub connectAccount {
#  #################################################################
#  #     Verbindung mit dem Account erstellen bzw. wiederherstellen
#  #     via MQL4_ZMQ, Ermitteln des Status und der aktuellen Orders
#  #     Proc 9
#  #     Eingabe: Account -> Accountnummer
#  #     Ausgabe: O: Account nicht verbunden
#  #              1: Account verbunden
#  my $self = shift;
#  my %args = (@_);
#
#  my $merker          = $self->{subroutine};
#  $self->{subroutine} = (caller(0))[3];
#  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));
#
#  # Info Responses subscriben  
#  $self->{ZMQ}->subscribeAccount('account', $args{account},
#                                 'typ',    'status',
#                                 'wert',   'bridge');
#  $self->{ZMQ}->subscribeAccount('account', $args{account},
#                                 'typ',    'info',
#                                 'wert',   'account');
#  $self->{ZMQ}->subscribeAccount('account', $args{account},
#                                 'typ',    'info',
#                                 'wert',   'order');
#  $self->{ZMQ}->subscribeAccount('account', $args{account},
#                                 'typ',    'info',
#                                 'wert',   'ema');
#  # Info Response einschalten
#  my $rc = $self->{ZMQ}->cmd('account', $args{account},
#                             'cmd',     'set_parameter',
#                             'name',    'get_info',
#                             'value',   '1');
#  
#  if ($rc) {
#    # Infos anfordern
#    my $statusinfo  = $self->{ZMQ}->getInfo('account', $args{account},
#                                            'typ',    'status',
#                                            'wert',   'bridge');
#    if ($statusinfo) {$rc = 1}
#    my $accountinfo = $self->{ZMQ}->getInfo('account', $args{account},
#                                            'typ',     'info',   
#                                            'wert',    'account');
#    # Lesen der aktuellen Orders
#    my $orderinfo   = $self->{ZMQ}->getInfo('account', $args{account},
#                                            'typ',     'info',   
#                                            'wert',    'order');
#    my $emainfo     = $self->{ZMQ}->getInfo('account', $args{account},
#                                            'typ',     'info',   
#                                            'wert',    'ema');
#
#    # Info Response ausschalten
#    $self->{ZMQ}->cmd('account', $args{account},
#                      'cmd',     'set_parameter',
#                      'name',    'get_info',
#                      'value',   '0');
#
#    # ToDo Alle Orders durchgehen und die ermitteln, fuer die wir zustaendig sind
#    # my $decoded = decode_json($json);
#    # my @friends = @{ $decoded->{'friends'} };
#    # foreach my $f ( @friends ) {
#    #   print $f->{"name"} . "\n";
#    # }
#    
#    if ($orderinfo) {
#      my @orders = @{$orderinfo->{'order'}};
#      foreach my $order (@orders) {
#        my %orderattribute;
#        while ((my $key, my $value) = each(%{$order})) {
#          $orderattribute{$key} = $value;
#        }
#        
#        # Verfuegbare Attribute
#        # ticket
#        # magic_number
#        # type
#        # pair
#        # open_price
#        # take_profit
#        # stop_loss
#        # profit
#        # lot
#        # comment
#        # open_time
#        # expire_time
#        if (defined($orderattribute{comment}) && $orderattribute{comment} =~ /(.*):FxAssist:ST/) {
#          $self->{Account}->{$args{account}}->{Signal}->{$1}->{Activ}  = 1;
#          $self->{Account}->{$args{account}}->{Signal}->{$1}->{UUID}   = $1;
#          $self->{Account}->{$args{account}}->{Signal}->{$1}->{Ticket} = $orderattribute{ticket};
#          $self->{Account}->{$args{account}}->{Signal}->{$1}->{SL}     = $orderattribute{stop_loss};
#          $self->{Account}->{$args{account}}->{Signal}->{$1}->{TP}     = $orderattribute{take_profit};
#        }                        
#      }
#    }
#    
#    # Info Responses unsubscriben  
#    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
#                                     'typ',    'status',
#                                     'wert',   'bridge');
#    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
#                                     'typ',    'info',
#                                     'wert',   'account');
#    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
#                                     'typ',    'info',
#                                     'wert',   'order');
#    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
#                                     'typ',    'info',
#                                     'wert',   'ema');
#    # Repondes subscriben
#    $rc = $self->{ZMQ}->subscribeAccount('typ',    'response',
#                                         'account', $args{account});
#  }
#  
#  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
#  $self->{subroutine} = $merker;
#
#  return $rc;
#}
 


1;
