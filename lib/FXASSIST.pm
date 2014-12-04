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
# Done Cookies zum Laufen bringen
# ToDo Ggf. LWP::RobotUA einsetzen
# ToDo ZMQ::LibZMQ2 Fehler cpanm install fixen Alternativ: LibZMQ3 oder LibZMQ4 Library fuer MT4
# ToDo ZeroMQ Telegramme definieren und auf beiden Seiten (Perl und MT4) implementieren
# ToDo Nach Abbruch der Internetverbindung: Use of uninitialized value in pattern match (m//) at /Users/pgk/Documents/00_Eclipse/FxAssist/lib/FXASSIST.pm line 431.
#      if (defined($self->{Store}->{Response}) &&
#          $self->{Store}->{Response}->is_success() &&
#          $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{Login}->{Title}/ &&
#          $self->{Store}->{Response}->content() =~ m/form[^>]*name="$self->{Store}->{Location}->{Login}->{Form}->{Name}"/ &&
#          $self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
# Done Reduzieren der Pollfrequenz nach Empfang eines Signals bis zum Ende des Signals (dazu ist Rueckmeldung des MT4 noetig, ob das Signal noch aktiv ist) -> Lazyfaktor
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
use ZMQ::LibZMQ4;
use ZMQ::FFI;

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
  
  if (Configuration->config('Prg', 'Plugin')) {

    # refs ausschalten wg. dyn. Proceduren
    no strict 'refs';
    my %plugin = ();

    # Bearbeiten aller Erweiterungsmodule die in der INI-Date
    # in Sektion [Prg] unter "Plugin =" definiert sind
    foreach (split(/ /, Configuration->config('Prg', 'Plugin'))) {

      # Falls ein Modul existiert
      if (-e "$self->{Pfad}/plugins/${_}.pm") {

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
  if (Configuration->config('Prg', 'LockFile')) {
    $self->{LockFile} = File::Spec->canonpath(Utils::extendString(Configuration->config('Prg', 'LockFile'), "BIN|$Bin|SCRIPT|" . uc($Script)));
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
  
  # Mit dem RobotUA wird das Warten automatisiert; leider kommen wir damit nicht rein
  # $self->{Browser} = LWP::RobotUA->new('Me/1.0', 'a@b.c');
  # $self->{Browser}->delay(60/60);  # avoid polling more often than every 1 minute
  $self->{Browser} = LWP::UserAgent->new( );
  $self->{Browser}->env_proxy();   # if we're behind a firewall
  
  if (Configuration->config('Prg', 'Cookie')) {
    $self->{Cookie} = Utils::extendString(Configuration->config('Prg', 'Cookie'), "BIN|$Bin|SCRIPT|" . uc($Script));
    if ($self->{Cookie} eq '1') {
      $self->{Browser}->cookie_jar({});
    } else {
      $self->{Browser}->cookie_jar(HTTP::Cookies->new('file'     => $self->{Cookie},
                                                      'autosave' => 1));
    }
  }

  if (Configuration->config('Prg', 'Storable')) {
    $self->{Storable} = Utils::extendString(Configuration->config('Prg', 'Storable'), "BIN|$Bin|SCRIPT|" . uc($Script));
     eval {$self->{Store} = retrieve $self->{Storable}};
  }
  
  # URL-Zugriff, Form- und Datenfelder definieren
  if (!defined($self->{Store}->{Location})) {
    my %config = Configuration->config();
    foreach my $section (keys %config) {
      next unless $section =~ /^Location (.*)$/;
      my $location = $1;
      while ((my $key, my $value) = each(%{$config{$section}})) {
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
    $self->{Store}->{Location}->{Lazyfaktor} = Configuration->config('Prg', 'Storable') || 10;
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


sub doDebugResponse {
  #################################################################
  #     Infos des Respondes ausgeben.
  #     Proc 1
  my $self  = shift;
  my $url   = shift;
  my $param = join('|', @_);
  
  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

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

  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
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
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

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

  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
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
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

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
  
  Trace->Trc( 'S', 3, 0x00002, $self->{subroutine} );
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
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  my $resp = $self->{Browser}->post(@_);
  $self->{Store}->{Response} = $resp;
  # Ggf. Redirection folgen
  while ($self->{Store}->{Response}->is_redirect) {
    $self->{Store}->{Response} = $self->{Browser}->get($self->{Store}->{Response}->header('location'));
  }
  $self->doDebugResponse(@_) if Trace->debugLevel() > 3;
#  # Ggf. Redirection folgen
#  while ($self->{Store}->{Response}->is_redirect) {$self->myGet($self->{Store}->{Response}->header('location'))}
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}

  Trace->Trc( 'S', 3, 0x00002, $self->{subroutine} );
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub action {
  #################################################################
  #     Dauerlaufrouting
  #     Proc 5
  #
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;
  
  if ($self->{Store}->{Location}->{Next} eq 'Login')  {$self->doLogin()}
  if ($self->{Store}->{Location}->{Next} eq 'GetIn')  {$self->doGetIn()}
  if ($self->{Store}->{Location}->{Next} eq 'GetOut') {$self->doGetOut()}
  
  # Ein Signal hat 2 Flags. In Abhaengigkeit von diesen sind dem 
  # MT4 unterschiedliche Instruktionen zu geben
  # Valid  Activ  Instruktion
  #   1      1    -
  #   1      0    Sende Eroeffnungsauftrag fuer diese Position
  #   0      1    Sende Schliessauftrag fuer diese Postition
  #   0      0    Das Signal ist erledigt und wird aus der Datenstruktur entfernt
  if (defined($self->{Store}->{Signal})) {
    foreach my $id (keys(%{$self->{Store}->{Signal}})) {
      if (defined($self->{Store}->{Signal}->{$id}) && (ref($self->{Store}->{Signal}->{$id}) eq 'HASH')) {
        $self->doDebugSignal($id) if Trace->debugLevel() > 3;
        if ( $self->{Store}->{Signal}->{$id}->{Valid} &&  $self->{Store}->{Signal}->{$id}->{Activ}) {next};
        if ( $self->{Store}->{Signal}->{$id}->{Valid} && !$self->{Store}->{Signal}->{$id}->{Activ}) {$self->sendMsg('open',$id)}
        if (!$self->{Store}->{Signal}->{$id}->{Valid} &&  $self->{Store}->{Signal}->{$id}->{Activ}) {$self->sendMsg('close',$id)}
        if (!$self->{Store}->{Signal}->{$id}->{Valid} && !$self->{Store}->{Signal}->{$id}->{Activ}) {delete($self->{Store}->{Signal}->{$id})}
      }
    }
  }
  

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
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
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));

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
#      Trace->Trc('I', 4, 0x02206, $self->{Store}->{Response}->headers_as_string());
      $self->{Store}->{Location}->{Next} = $self->{Store}->{Location}->{Login}->{Next};
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
      $rc = 1;    
    }
  } else {
    if (defined($self->{Store}->{Response}) && !$self->{Store}->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a600, $self->{Store}->{Response}->status_line(), 'Login'); 
    }
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
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
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
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

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
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
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
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

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub sendMsg {
  #################################################################
  #     Kommunikation mit dem MT4
  #     Proc 9
  #     Eingabe: Operation: open|close
  #              ID: Signal-ID
  #     
  #     Die eigentliche Kommunikation findet in sub IO() statt
  #     Bei Erfolg sollte sub IO eine 1 zurueckmelden, bei Misserfolg eine 0
  #     Im Erfolgsfall open muß $self->{Store}->{Signal}->{$id}->{Activ} auf 1 gesetzt werden.
  #     Im Erfolgsfall close muß $self->{Store}->{Signal}->{$id}->{Activ} auf 0 gesetzt werden.
  #
  # ToDo Rueckmeldung des MT4: Position offen/geschlossen holen und auswerten
  my $self = shift;
  my $op   = shift;
  my $id   = shift;
  
  sub IO() {
    return 1
  } 

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;
  
  if ($op eq 'open') {
    Trace->Trc('I', 1, 0x02900, $id);
    my $oprc = IO();
    if ($oprc) {
      # Open erfolgreich. Signal ist aktiviert
      $self->{Store}->{Signal}->{$id}->{Activ} = 1;
      Trace->Trc('I', 1, 0x02901, $id);
    } else {
      Trace->Trc('I', 1, 0x0a900, $id);
    }
  }
  if ($op eq 'close') {
    Trace->Trc('I', 1, 0x02902, $id);
    my $oprc = IO();
    if ($oprc) {
      # Close erfolgreich. Signal ist deaktiviert
      $self->{Store}->{Signal}->{$id}->{Activ} = 0;
      Trace->Trc('I', 1, 0x02903, $id);
    } else {
      Trace->Trc('I', 1, 0x0a901, $id);
    }
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


1;
