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
#      if (defined($self->{Store}->{Response}) &&
#          $self->{Store}->{Response}->is_success() &&
#          $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{Login}->{Title}/ &&
#          $self->{Store}->{Response}->content() =~ m/form[^>]*name="$self->{Store}->{Location}->{Login}->{Form}->{Name}"/ &&
#          $self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
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
#use LWP::RobotUA;
use HTTP::Cookies;

use HTML::Entities;
use utf8;
use Text::Unidecode;

use Storable;

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
  

  # Anlegen der ZMQ Verbindung
  $self->{ZMQ} = MQL4_ZMQ->new('PubAddr' => $cfg{ZMQ}{PubAddr} || '4711',
                               'SubAddr' => $cfg{ZMQ}{SubAddr} || '4712');

  # Einlesen aller konfigurierten Kontoverbindungen
  foreach my $section (keys %cfg) {
    next unless $section =~ /^Account (.*)$/;
    my $account = $1;
    while ((my $key, my $value) = each(%{$cfg{$section}})) {
      $self->{Account}->{$account}->{$key} = Utils::extendString($value);
    }
    if (defined($account) && 
        defined($self->{Account}->{$account}->{MagicNumber}) &&
        defined($self->{Account}->{$account}->{Symbol})) {
      $self->{Account}->{$account}->{Connected} = $self->connectAccount('account' => $account);
    } else {
      delete($self->{Account}->{$account});
    }
  }
   
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
  $self->{Cron} = $cfg{Prg}{Aktiv};
  
  # Falls Persistenz definiert ist wird die Datenstruktur aus der Persistenzdatei geladen
  if ($cfg{Prg}{Storable}) {
    $self->{Storable} = Utils::extendString($cfg{Prg}{Storable}, "BIN|$Bin|SCRIPT|" . uc($Script));
     eval {$self->{Store} = retrieve $self->{Storable}};
  }
  
  # URL-Zugriff, Form- und Datenfelder definieren
  if (!defined($self->{Store}->{Location})) {
    foreach my $section (keys %cfg) {
      next unless $section =~ /^Location (.*)$/;
      my $location = $1;
      while ((my $key, my $value) = each(%{$cfg{$section}})) {
        (my $key1, my $value1) = split(' ', $key);
        if (defined($value1)) {
          $self->{Store}->{Location}->{$location}->{$key1}->{$value1} = Utils::extendString($value);
        } else {
          $self->{Store}->{Location}->{$location}->{$key} = Utils::extendString($value);
        }
      }
    }
    $self->{Store}->{Location}->{Last}       = '';
    $self->{Store}->{Location}->{Next}       = 'Login';
    $self->{Store}->{Location}->{Delay}      = 0;
    $self->{Store}->{Location}->{Lazyfaktor} = $cfg{Prg}{Lazyfaktor} || 10;
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  }
  
  $self->{Store}->{Signal}->{Aktuell} = 0;

  Trace->Exit(1, 0, 0x08002, 'Location') if (!defined($self->{Store}->{Location}));
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
  Trace->Trc('I', 4, 0x02100, 'Status',               defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->status_line() : '-');
  Trace->Trc('I', 4, 0x02100, 'Title',                defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->header('title') : 'Response nicht definiert.');
  Trace->Trc('I', 4, 0x02100, 'Success',              defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_success() ? 'yes' : 'no'  : '-');
  Trace->Trc('I', 4, 0x02100, 'Redirection',          defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_redirect() ? 'yes' : 'no' : '-');
  Trace->Trc('I', 4, 0x02100, 'Header',               defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->headers_as_string() : '-');
  Trace->Trc('I', 4, 0x02100, 'Document valid until', defined($self->{Store}->{Response}) ? scalar(localtime($self->{Store}->{Response}->fresh_until())) : '-');
  my ($form, $action);
  if (defined($self->{Store}->{Response})) {
    if ($self->{Store}->{Response}->content() =~ m/form[^>]*name="($self->{Store}->{Location}->{Login}->{Form}->{Name})"/) {$form = $1};  
    if ($self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {$action = $1};
  }
  Trace->Trc('I', 4, 0x02100, 'Form',   defined($form) ? $form : '-');
  Trace->Trc('I', 4, 0x02100, 'Action', defined($action) ? $action : '-');
  Trace->Trc('I', 5, 0x02100, 'Content', defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->decoded_content() : '-');

  Trace->Trc('S', 3, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub doDebugSignal {
  #################################################################
  #     Infos des Signals ausgeben.
  #     Proc 2
  my $self = shift;
  my $id   = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, $id);

  my $rc = 0;

  Trace->Trc('I', 1, 0x02200, "  Aktuell:          ", $self->{Store}->{Signal}->{Aktuell});
  Trace->Trc('I', 1, 0x02200, "  ID:               ", $id);
  my $signaldefiniert = defined($self->{Store}->{Signal}->{$id});
  Trace->Trc('I', 1, 0x02200, "  Signal definiert: ", $signaldefiniert ? 'Ja' : 'Nein -> Altes Signal');
  if ($signaldefiniert) {
    Trace->Trc('I', 1, 0x02200, "  Gueltig:          ", $self->{Store}->{Signal}->{$id}->{Valid} ? 'Ja' : 'Nein');
    Trace->Trc('I', 1, 0x02200, "  Aktiv:            ", $self->{Store}->{Signal}->{$id}->{Activ} ? 'Ja' : 'Nein');
    Trace->Trc('I', 1, 0x02200, "  Signal:           ", $self->{Store}->{Signal}->{$id}->{Signal});
    Trace->Trc('I', 1, 0x02200, "  Stand:            ", $self->{Store}->{Signal}->{$id}->{Stand});
    Trace->Trc('I', 1, 0x02200, "  Zeit:             ", $self->{Store}->{Signal}->{$id}->{Zeit});
    Trace->Trc('I', 1, 0x02200, "  Stopp-Loss-Marke: ", $self->{Store}->{Signal}->{$id}->{SL});
    Trace->Trc('I', 1, 0x02200, "  Take-Profit_Marke:", $self->{Store}->{Signal}->{$id}->{TP});
  }

  Trace->Trc('S', 3, 0x00002, $self->{subroutine}, $rc);
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
  if (defined($self->{Store}->{Location}->{$type})) {
    # Delay noetig, falls kein Redirect oder Statusabfrage
    $url = $self->{Store}->{Location}->{$type}->{URL};
    my $delay = $self->{Store}->{Location}->{$type}->{Delay} || 60;
    if (defined($self->{Store}->{Signal}) && defined($self->{Store}->{Signal}->{Aktuell}) &&
        defined($self->{Store}->{Signal}->{$self->{Store}->{Signal}->{Aktuell}}) &&
        $self->{Store}->{Signal}->{$self->{Store}->{Signal}->{Aktuell}}->{Valid} &&
        $self->{Store}->{Signal}->{$self->{Store}->{Signal}->{Aktuell}}->{Valid}) {
      $delay = 10 * $self->{Store}->{Location}->{Lazyfaktor};
    }
    while (time() - $self->{Store}->{Location}->{Delay} < $delay) {
      Trace->Trc('I', 4, 0x02300, time() - $self->{Store}->{Location}->{Delay}, $delay);
      sleep $delay - (time() - $self->{Store}->{Location}->{Delay});
    }
    Trace->Trc('I', 4, 0x02301, time() - $self->{Store}->{Location}->{Delay}, $delay);
    $self->{Store}->{Location}->{Delay} = time();
  }
  $self->{Store}->{Response} = $self->{Browser}->get($url, @_);
  # Ggf. Redirection folgen
  while ($self->{Store}->{Response}->is_redirect) {
    $self->{Store}->{Response} = $self->{Browser}->get($self->{Store}->{Response}->header('location'));
  }
  $self->doDebugResponse($url, @_) if Trace->debugLevel() > 3;
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  
  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub myPost {
  #################################################################
  #     Formular absenden 
  #     Proc 4
  # Parameters:
  #  the URL,
  #  an arrayref or hashref for the key/value pairs,
  #  and then, optionally, any header lines: (key,value, key,value)
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine});

  my $resp = $self->{Browser}->post(@_);
  $self->{Store}->{Response} = $resp;
  # Ggf. Redirection folgen
  while ($self->{Store}->{Response}->is_redirect) {
    $self->{Store}->{Response} = $self->{Browser}->get($self->{Store}->{Response}->header('location'));
  }
  $self->doDebugResponse(@_) if Trace->debugLevel() > 3;
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}

  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub EA_Kommunikation {
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
  
  sub readResponse {
    #################################################################
    #     Procedure zum Einlesen der EA Response
    sleep(shift);
    while (my $response = ($self->{ZMQ}->getResponse())) {
      # Antwort: response|[account name] {"response": "[response]"}
      #              account : Betroffenes Konto
      #              referenz: [Referenz ID]
      #              cmd:      Original Kommando
      #              status  : Gesamtergebnis: 0: Nicht erfolgreich
      #                                        1: Erfolgreich
      #
      #              Weitere moegliche Elemente:
      #              ticket   : Ticket ID 
      #              msg      : Nachrichten Freitext
      #              name     : Parameter Name
      #              value    : abgefragter/zu setzender Wert
      if (defined($self->{Account}->{$response->{account}})) {
        my $account  = $response->{account};
        my $referenz = $response->{referenz};
        my $cmd      = $response->{cmd};
        my $status   = $response->{status};

        my $ticket   = $response->{ticket};
        
        my $accounthash   = $self->{Account}->{$account};
        my $parameterhash = $accounthash->{Signal}->{$signalid}->{Parameter};
        
        if (my $signalid = $parameterhash->{signal}) {
          if ($status && $ticket && $signalid) {
            if ($cmd eq 'set')   {$accounthash->{Signal}->{$signalid}->{Activ} = 1}
            if ($cmd eq 'unset') {$accounthash->{Signal}->{$signalid}->{Activ} = 0}
            $accounthash->{Signal}->{$signalid}->{Ticket} = $ticket;
          } 
          delete ($accounthash->{Signal}->{$signalid}->{Parameter});
        } 
      }
    }
  }
 
  # Alle Steps werden fue jeden Account ausgefuehrt. Dazu hat jeder
  # Step eine eigene Schleife, da die Ergebnisse der vorhergehenden 
  # Schleife u.U. dazu fuehren, das die nachfolgende Schleife nicht
  # ueber alle Accounts ausgefuehrt wird
  
  # Step 0: Verbinden der Account, falls noch nicht geschehen
  # Falls die Accounts nicht verbunden sind verbinden wir sie erst einmal und ermitteln
  # die aktuellen Orders
  foreach my $account (keys(%{$self->{Account}})) {
    next if $self->{Account}->{$account}->{Connected};
    $self->{Account}->{$account}->{Connected} = $self->connectAccount('account' => $account);
  }
  
  # Step 1: Einlesen der Schnittstelle und Auswerten der gelesenen Signale
  readResponse(0);

  # Step 2: Ausfuehren der EA-IO und ggf. Bereinigen der Datenstruktur
  # Ein Signal hat 2 Flags. In Abhaengigkeit von diesen sind  
  # unterschiedliche Instruktionen zu geben
  # Aktiv  Valid  Instruktion
  #   1      0    Sende Schliessauftrag fuer diese Postition
  #   1      1    -
  #   0      1    Sende Eroeffnungsauftrag fuer diese Position
  #   0      0    Das Signal ist erledigt und wird aus der Datenstruktur entfernt
  #               Falls das Signal fuer keinen Account mehr aktiv ist wird es geloescht
  if (defined($self->{Store}->{Signal})) {
    my $EA_IO = 0;
    foreach my $id (keys(%{$self->{Store}->{Signal}})) {
      if (defined($self->{Store}->{Signal}->{$id}) && (ref($self->{Store}->{Signal}->{$id}) eq 'HASH')) {
        $self->doDebugSignal($id) if Trace->debugLevel() > 3;
        my $deleteSignal = 1;
        foreach my $account (keys(%{$self->{Account}})) {
          next if !$self->{Account}->{$account}->{Connected};
          if ($self->{Account}->{$account}->{Signal}->{$id}->{Activ}) {
            # Signal fuer diesen Account aktiv -> nicht loeschen
            $deleteSignal = 0;
            if (!$self->{Store}->{Signal}->{$id}->{Valid}) {
              # Signal nicht valide -> Trade schliessen
              $EA_IO = 1;
              if (defined($self->{Account}->{$account}->{Signal}->{$id}->{Parameter})) {
                # Signalschliessung wurde bereits versendet, ist aber noch nicht quittiert, daher senden wir nochmal.
                # Der MT4 muss anhand der Referenz Sorge tragen, dass es nicht zu Doppelausfuehrungen kommt
                $self->{ZMQ}->cmd($self->{Account}->{$account}->{Signal}->{$id}->{Parameter});
              } else {
                # Signalschliessung wurde noch nicht versendet
                my $parameter = {'account',      $account,
                                 'cmd',          'unset',
                                 'ticket',       $self->{Account}->{$account}->{Signal}->{$id}->{Ticket}};
                $parameter->{referenz} = $self->{ZMQ}->cmd($parameter);
                $self->{Account}->{$account}->{Signal}->{$id}->{Parameter} = $parameter; 
              }
            }  
          } else {
            # Signal fuer diesen Account nicht aktiv
            if ($self->{Store}->{Signal}->{$id}->{Valid}) {
              # Signal valide -> Trade eroeffnen
              $EA_IO = 1;
              $deleteSignal = 0;
              if (defined($self->{Account}->{$account}->{Signal}->{$id}->{Parameter})) {
                # Signaleroeffnung wurde bereits versendet, ist aber noch nicht quittiert, daher senden wir nochmal.
                # Der MT4 muss anhand der Referenz Sorge tragen, dass es nicht zu Doppelausfuehrungen kommt
                $self->{ZMQ}->cmd($self->{Account}->{$account}->{Signal}->{$id}->{Parameter});
              } else {
                # Signaleroeffnung wurde noch nicht versendet
                my $orderart;
                if ($self->{Store}->{Signal}->{$id}->{Signal} =~ /Long$/)  {$orderart = 0}
                if ($self->{Store}->{Signal}->{$id}->{Signal} =~ /Short$/) {$orderart = 1}
                my $parameter = {'account',      $account,
                                 'cmd',          'set',
                                 'type',         $orderart, 
                                 'pair',         $self->{Account}->{$account}->{Symbol}, 
                                 'magic_number', $self->{Account}->{$account}->{MagicNumber}, 
                                 'comment',      'Opened by FxAssist:ST:' . $id, 
                                 'signal',       $id,
                                 'lot',          '0.5'};
                $parameter->{referenz} = $self->{ZMQ}->cmd($parameter);
                $self->{Account}->{$account}->{Signal}->{$id}->{Parameter} = $parameter; 
              }
            } else {
              # Signal nicht valide -> Signal fuer diesen Account loeschen
              delete($self->{Account}->{$account}->{Signal}->{$id});
            }  
          }
        }
        delete($self->{Store}->{Signal}->{$id}) if $deleteSignal;
      }
    }
    if ($EA_IO) {
      # Es hat eine IO zum EA stattgefunden daher warten wir eine Sekunde und 
      # lesen nochmal den Response
      readResponse(1);
    }
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

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
  
  # Falls ein Aktivitaetszeitraum gesetzt ist, wird so eine Sekunde geschlafen
  if (defined($self->{Cron}) && Schedule::Cron->get_next_execution_time($self->{Cron}) > time) {
    # sleep (Schedule::Cron->get_next_execution_time($self->{Cron}) - time);
    sleep 1;
  } else {
    if (Configuration->config('Prg', 'Fake')) {
      $self->{Store}->{Signal}->{Aktuell}          = '1234';
      $self->{Store}->{Signal}->{'1234'}->{Valid}  = 1;
      $self->{Store}->{Signal}->{'1234'}->{Activ}  = 0;
      $self->{Store}->{Signal}->{'1234'}->{Signal} = 'DAX Short';
      $self->{Store}->{Signal}->{'1234'}->{Stand}  = '9427';
      $self->{Store}->{Signal}->{'1234'}->{Zeit}   = '20.11.2014 – 09:45 Uhr';
      $self->{Store}->{Signal}->{'1234'}->{SL}     = '9455';
      $self->{Store}->{Signal}->{'1234'}->{TP}     = '9399';
    } else {
      if ($self->{Store}->{Location}->{Next} eq 'Login')  {$self->doLogin()}
      if ($self->{Store}->{Location}->{Next} eq 'GetIn')  {$self->doGetIn()}
      if ($self->{Store}->{Location}->{Next} eq 'GetOut') {$self->doGetOut()}
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
  $self->{Store}->{Location}->{Last} = 'Login';

  # Auswerten des Response und bei Erfolg Einloggen (Form ausfuellen und abschicken)
  if (defined($self->{Store}->{Response}) &&
      $self->{Store}->{Response}->is_success() &&
      $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{Login}->{Title}/ &&
      $self->{Store}->{Response}->content() =~ m/form[^>]*name="$self->{Store}->{Location}->{Login}->{Form}->{Name}"/ &&
      $self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
    my $action = $1;
    Trace->Trc('I', 4, 0x02601, $self->{Store}->{Response}->status_line());
    my %formvalues;
    while ((my $key, my $value) = each(%{$self->{Store}->{Location}->{Login}->{Form}})) {
      next if ($key eq "Name");
      $formvalues{$key} = Utils::extendString($value, , "URL|$self->{Store}->{Location}->{Login}->{URL}");
    }
    # Einloggen
    $self->myPost($action, [%formvalues]);
    
    # Auswerten den Einlog Responses und bei Erfolg Weiterschalten der Location auf GetIn
    if ($self->{Store}->{Response}->is_success &&
       ($self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{$self->{Store}->{Location}->{Login}->{Next}}->{Title}/)) {
      Trace->Trc('I', 1, 0x02602, $self->{Store}->{Response}->status_line(), $self->{Store}->{Location}->{Login}->{Next});
      $self->{Store}->{Location}->{Next} = $self->{Store}->{Location}->{Login}->{Next};
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
      $rc = 1;    
    }
  } else {
    if (defined($self->{Store}->{Response}) && !$self->{Store}->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a600, $self->{Store}->{Response}->status_line(), 'Login'); 
    }
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
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
  if ($self->{Store}->{Location}->{Last} eq 'Login') {
    # Seite wurde bereits im Rahmen des Login geholt, daher kein erneutes Laden,
    # falls wir von der Location Login kommen
    Trace->Trc('I', 4, 0x02700, $self->{Store}->{Location}->{Last} || 'Neustart', 'GetIn');
    $self->{Store}->{Location}->{Last} = 'GetIn';
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  } else {
    Trace->Trc('I', 2, 0x02701);
    $self->myGet('GetIn');
  }

  # Holen der Seite erfolgreich ?  
  if (defined($self->{Store}->{Response}) &&
      $self->{Store}->{Response}->is_success && 
      $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{GetIn}->{Title}/) {
    Trace->Trc('I', 1, 0x02702, $self->{Store}->{Response}->status_line(), 'GetIn');
 
    # Auswertung der Daten
    my %signal;
    my $content = $self->{Store}->{Response}->decoded_content();
    open IN, '<', \$content or die $!;
    while (<IN>) {
      my $line = $_;
      while ((my $key, my $value) = each(%{$self->{Store}->{Location}->{GetIn}->{Field}})) {
        if ($line =~ /$value/) {
          $signal{$key} = decode_entities($1);
          $signal{$key} =~ s/([^[:ascii:]]+)/unidecode($1)/ge;
        };
      }
    }
    close(IN);

    if (defined($signal{ID}) && $signal{ID} && ($self->{Store}->{Signal}->{Aktuell} ne $signal{ID})) {
      # Neues Signal      
      Trace->Trc('I', 1, 0x02703, $signal{ID});
      undef($self->{Store}->{Signal}->{$signal{ID}});
      # Neues Signal vorhanden. Altes Signal ist damit ungueltig
      $self->{Store}->{Signal}->{$self->{Store}->{Signal}->{Aktuell}}->{Valid} = 0 if ($self->{Store}->{Signal}->{Aktuell});
      $self->{Store}->{Signal}->{Aktuell} = $signal{ID};
      $self->{Store}->{Signal}->{$signal{ID}}->{Valid} = 1;
      $self->{Store}->{Signal}->{$signal{ID}}->{Activ} = 0;
      while ((my $key, my $value) = each %signal) {$self->{Store}->{Signal}->{$signal{ID}}->{$key} = $value unless ($key eq 'ID')}  
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}};
    }
    $self->doDebugSignal($signal{ID}) if Trace->debugLevel() > 3;
    
    if (defined($self->{Store}->{Signal}->{$signal{ID}})) {
      # Holen des Signals erfolgreich: Weiter mit Checken der Historienseite
      $self->{Store}->{Location}->{Next} = 'GetOut';
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
    }
  } else {
    # Holen der Werte nicht erfolgreich: Weiterschalten mit Login
    if (defined($self->{Store}->{Response}) && !$self->{Store}->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a700, $self->{Store}->{Response}->status_line(), 'Login'); 
    }
    $self->{Store}->{Location}->{Next} = 'Login';
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
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

  $self->{Store}->{Location}->{Last} = 'GetOut';
  
  if (defined($self->{Store}->{Signal})) {
    foreach my $id (keys(%{$self->{Store}->{Signal}})) {
      if (defined($self->{Store}->{Signal}->{$id}) && (ref($self->{Store}->{Signal}->{$id}) eq 'HASH')) {      
        $self->doDebugSignal($id) if Trace->debugLevel() > 3;
        next unless ($self->{Store}->{Signal}->{$id}->{Valid});
        my $zeit = $self->{Store}->{Signal}->{$id}->{Zeit};
        if ($zeit =~ /([0-9]{2})\.([0-9]{2})\.([0-9]{4})/) {
          my ($d, $m, $j) = ($1, $2, $3);
          my $url = Utils::extendString($self->{Store}->{Location}->{GetOut}->{URL}, "ID|$id|DAY|$d|MONTH|$m|YEAR|$j");
          Trace->Trc('I', 2, 0x02800, $id);
          $self->myGet($url);
          if (defined($self->{Store}->{Response})) {
            Trace->Trc('I', 1, 0x02801, $self->{Store}->{Response}->status_line(), $id);
            # Historieneintrag vorhanden. Signal ist damit ungueltig
            $self->{Store}->{Signal}->{$id}->{Valid} = 0;
          } else {
            Trace->Trc('I', 4, 0x02802, $self->{Store}->{Response}->status_line(), $id);
          }
        }
      }
    }
  }
  Trace->Trc('I', 4, 0x02803, 'GetIn');
  # Unabhaengig vom Ergebnis des Check weitermachen mit der Ermittelung des aktuellen Wertes
  $self->{Store}->{Location}->{Next} = 'GetIn';
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}

  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}


sub connectAccount {
  #################################################################
  #     Verbindung mit dem Account erstellen bzw. wiederherstellen
  #     via MQL4_ZMQ, Ermitteln des Status und der aktuellen Orders
  #     Proc 9
  #     Eingabe: Account -> Accountnummer
  #     Ausgabe: O: Account nicht verbunden
  #              1: Account verbunden
  my $self = shift;
  my %args = (@_);

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, join(' ', %args));

  # Info Responses subscriben  
  $self->{ZMQ}->subscribeAccount('account', $args{account},
                                 'typ',    'status',
                                 'wert',   'bridge');
  $self->{ZMQ}->subscribeAccount('account', $args{account},
                                 'typ',    'info',
                                 'wert',   'account');
  $self->{ZMQ}->subscribeAccount('account', $args{account},
                                 'typ',    'info',
                                 'wert',   'order');
  $self->{ZMQ}->subscribeAccount('account', $args{account},
                                 'typ',    'info',
                                 'wert',   'ema');
  # Info Response einschalten
  my $rc = $self->{ZMQ}->cmd('account', $args{account},
                             'cmd',     'parameter',
                             'name',    'get_info',
                             'value',   '1');
  
  if ($rc) {
    # Infos anfordern
    my $statusinfo  = $self->{ZMQ}->getInfo('account', $args{account},
                                            'typ',    'status',
                                            'wert',   'bridge');
    if ($statusinfo) {$rc = 1}
    my $accountinfo = $self->{ZMQ}->getInfo('account', $args{account},
                                            'typ',     'info',   
                                            'wert',    'account');
    # Lesen der aktuellen Orders
    my $ordersinfo  = $self->{ZMQ}->getInfo('account', $args{account},
                                            'typ',     'info',   
                                            'wert',    'order');
    my $emainfo     = $self->{ZMQ}->getInfo('account', $args{account},
                                            'typ',     'info',   
                                            'wert',    'ema');

    # Info Response ausschalten
    $self->{ZMQ}->cmd('account', $args{account},
                      'cmd',     'parameter',
                      'name',    'get_info',
                      'value',   '0');

    # ToDo Alle Orders durchgehen und die ermitteln, fuer die wir zustaendig sind
    if ($ordersinfo) {
      while ((my $key, my $value) = each(%{$ordersinfo})) {
        if ($key eq 'comment' && $value =~ /Opened by FxAssist:ST:(.*)/) {
          $self->{Account}->{$args{account}}->{Signal}->{$1}->{Activ} = 1;
          $self->{Account}->{$args{account}}->{Signal}->{$1}->{Ticket} = 1;
        }                        
      }
    }
    
    # Info Responses unsubscriben  
    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
                                     'typ',    'status',
                                     'wert',   'bridge');
    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
                                     'typ',    'info',
                                     'wert',   'account');
    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
                                     'typ',    'info',
                                     'wert',   'order');
    $self->{ZMQ}->unsubscribeAccount('account', $args{account},
                                     'typ',    'info',
                                     'wert',   'ema');
    # Repondes subscriben
    $rc = $self->{ZMQ}->subscribeAccount('typ',    'response',
                                         'account', $args{account});
  }
  
  Trace->Trc('S', 2, 0x00002, $self->{subroutine}, $rc);
  $self->{subroutine} = $merker;

  return $rc;
}
 


1;
