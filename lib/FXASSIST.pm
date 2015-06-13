package FXASSIST;

#-------------------------------------------------------------------------------------------------
# Letzte Aenderung:     $Date: $
#                       $Revision: $
#                       $Author: $
#
# Aufgabe:		- Ausfuehrbarer Code von fxassist.pl
#
# ToDo Implentierung cronaehnlicher Aktivitaetssteuerung (Schedule::Cron?)
# ToDo Storables zun Laufen bringen falls moeglich
# Done Cookies zum Laufen bringen
# ToDo Ggf. LWP::RobotUA einsetzen
# ToDo ZMQ::LibZMQ2 Fehler cpanm install fixen Alternativ: LibZMQ3 oder LibZMQ4 Library fuer MT4
# ToDo ZeroMQ Telegramme definieren und auf beiden Seiten (Perl und MT4) implementieren
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
#use DBAccess;
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
#use ZMQ::LibZMQ4;
#use ZMQ::FFI;

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
    $self->{Store}->{Location}->{Last} = '';
    $self->{Store}->{Location}->{Next} = 'Login';
    $self->{Store}->{Location}->{Delay} = 0;
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  }

  Trace->Exit(1, 0, 0x08002, 'Location') if (!defined($self->{Store}->{Location}));
  #Trace->Exit(1, 0, 0x08002, 'Location', 'URL')      if (!($self->{URL}      = Utils::extendString(Configuration->config('Location', 'URL'))));
  #Trace->Exit(1, 0, 0x08002, 'Location', 'Login')    if (!($self->{Login}    = Utils::extendString(Configuration->config('Location', 'Login'), "URL|$self->{URL}")));
  #Trace->Exit(1, 0, 0x08002, 'Location', 'Data')     if (!($self->{Data}     = Utils::extendString(Configuration->config('Location', 'Data'), "URL|$self->{URL}")));
  #Trace->Exit(1, 0, 0x08002, 'Location', 'Name')     if (!($self->{Name}     = Configuration->config('Location', 'Name')));
  #Trace->Exit(1, 0, 0x08002, 'Location', 'Password') if (!($self->{Password} = Configuration->config('Location', 'Password')));
  
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


sub action {
  #################################################################
  #     Dauerlaufrouting
  #
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;
  
  if ($self->{Store}->{Location}->{Next} eq 'Login') {$self->doLogin()}
  if ($self->{Store}->{Location}->{Next} eq 'Data')  {$self->getData()}

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  # Explizite Uebergabe des Returncodes noetig, da sonst ein Fehler auftritt
  return $rc;
}


sub delay {
  #################################################################
  #     Verzoegert den Request falls noetig.
  #     Proc 4
  my $self = shift;
  my $type = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  my $rc = 0;
  
  my $delay = $self->{Store}->{Location}->{$type}->{Delay} || 60;
  while (time() - $self->{Store}->{Location}->{Delay} < $delay) {
    Trace->Trc('I', 4, 0x02400, time() - $self->{Store}->{Location}->{Delay}, $delay);
    sleep 10;
  }

  Trace->Trc('I', 4, 0x02401, time() - $self->{Store}->{Location}->{Delay}, $delay);
  $self->{Store}->{Location}->{Delay} = time();

  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub doDebug {
  #################################################################
  #     Infos des Respondes ausgeben.
  #     Proc 1
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  my $rc = 0;

  Trace->Trc('I', 4, 0x02100, $self->{Store}->{Response}->status_line());
  Trace->Trc('I', 4, 0x02101, $self->{Store}->{Response}->headers_as_string());

  Trace->Trc('I', 4, 0x02103, scalar(localtime($self->{Store}->{Response}->fresh_until( ))));

  Trace->Trc('S', 3, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  return $rc;
}


sub myGet {
  # Parameters: the URL,
  #  and then, optionally, any header lines: (key,value, key,value)
  my $self = shift;
  my $type = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  my $url = $type;
  if (defined($self->{Store}->{Location}->{$type})) {
    # Redirect: kein delay noetig
    $url = $self->{Store}->{Location}->{$type}->{URL};
    $self->delay($type);
  }
  # $self->{Browser} = LWP::UserAgent->new( ) unless $self->{Browser};
  my $resp = $self->{Browser}->get($url, @_);
  $self->{Store}->{Response} = $resp;
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  $self->doDebug() if Trace->debugLevel() > 3;
  
  Trace->Trc( 'S', 3, 0x00002, $self->{subroutine} );
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub myPost {
  # Parameters:
  #  the URL,
  #  an arrayref or hashref for the key/value pairs,
  #  and then, optionally, any header lines: (key,value, key,value)
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 3, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  $self->delay('Login');
  # $self->{Browser} = LWP::UserAgent->new( ) unless $self->{Browser};
  my $resp = $self->{Browser}->post(@_);
  $self->{Store}->{Response} = $resp;
  if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  $self->doDebug() if Trace->debugLevel() > 3;

  Trace->Trc( 'S', 3, 0x00002, $self->{subroutine} );
  $self->{subroutine} = $merker;

  #return ($resp->content, $resp->status_line, $resp->is_success, $resp) if wantarray;
  #return unless $resp->is_success;
  #return $resp->content;
}


sub doLogin {
  #################################################################
  #     Einloggen
  #     Proc 2
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));

  my $rc = 0;

  if ($self->{Store}->{Location}->{Last} eq 'Login') {
    Trace->Trc('I', 1, 0x02201);
    # Das waere einfacher, aber es werden keine freundlichen Robots reingelassen
    # $self->{Browser}->delay($self->{Store}->{Location}->{Login}->{Delay}/60);
    $self->myGet('Login');
  } else {
    Trace->Trc('I', 4, 0x02200, $self->{Store}->{Location}->{Last} || 'Neustart', 'Login');
    $self->{Store}->{Location}->{Last} = 'Login';
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  }

  if (defined($self->{Store}->{Response}) &&
      $self->{Store}->{Response}->is_success() &&
      $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{Login}->{Title}/ &&
      $self->{Store}->{Response}->content() =~ m/form[^>]*name="$self->{Store}->{Location}->{Login}->{Form}->{Name}"/ &&
      $self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
    my $action = $1;
    Trace->Trc('I', 4, 0x02203, $self->{Store}->{Response}->status_line());
    my %formvalues;
    while ((my $key, my $value) = each(%{$self->{Store}->{Location}->{Login}->{Form}})) {
      next if ($key eq "Name");
      $formvalues{$key} = Utils::extendString($value, , "URL|$self->{Store}->{Location}->{Login}->{URL}");
    }
    $self->myPost($action, [%formvalues]);
    while ($self->{Store}->{Response}->is_redirect) {
      Trace->Trc('I', 4, 0x02205, $self->{Store}->{Response}->header('location'), $self->{Store}->{Response}->status_line());
      $self->myGet($self->{Store}->{Response}->header('location'));
      Trace->Trc('I', 4, 0x02208, $self->{Store}->{Response}->status_line());
      $self->doDebug() if Trace->debugLevel() > 3;
    }
    
    my $response = $self->{Store}->{Response};
    my $last = $response;
    my $message;
    while ($response) {
      $message .= $response->code( ) . " after ";
      $last = $response;
      $response = $response->previous( );
    }
    $message .= "the original request, which was:\n" . $last->request->as_string;
    Trace->Trc('I', 4, 0x02209, $message);
    
    if ($self->{Store}->{Response}->is_success &&
       ($self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{$self->{Store}->{Location}->{Login}->{Next}}->{Title}/)) {
      Trace->Trc('I', 1, 0x0220a, $self->{Store}->{Response}->status_line(), $self->{Store}->{Location}->{Login}->{Next});
      Trace->Trc('I', 4, 0x02206, $self->{Store}->{Response}->headers_as_string());
      $self->{Store}->{Location}->{Next} = $self->{Store}->{Location}->{Login}->{Next};
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
      $rc = 1;    
    } else {
      Trace->Trc('I', 4, 0x02204, 'Status',      defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->status_line() : '-');
      Trace->Trc('I', 4, 0x02204, 'Title',       defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->header('title') : 'Response nicht definiert.');
      Trace->Trc('I', 4, 0x02204, 'Success',     defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_success() ? 'yes' : 'no'  : '-');
      Trace->Trc('I', 4, 0x02204, 'Redirection', defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_redirect() ? 'yes' : 'no' : '-');
    }
  } else {
    Trace->Trc('I', 4, 0x02204, 'Status',      defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->status_line() : 'Neustart oder undefinierter Fehler');
    Trace->Trc('I', 4, 0x02204, 'Title',       defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->header('title') : 'Response nicht definiert.');
    Trace->Trc('I', 4, 0x02204, 'Success',     defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_success() ? 'yes' : 'no'  : '-');
    Trace->Trc('I', 4, 0x02204, 'Redirection', defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_redirect() ? 'yes' : 'no' : '-');
    my $dummy;
    if (defined($self->{Store}->{Response})) {
      $dummy = $self->{Store}->{Response}->content() =~ m/form[^>]*name="$self-->{Store}>{Location}->{Login}->{Form}"/;  
    }
    Trace->Trc('I', 4, 0x02204, 'Form ' . $self->{Store}->{Location}->{Login}->{Form}, defined($dummy) ? 'found' : 'not found');
    $dummy = undef;
    if (defined($self->{Store}->{Response})) {
      if ($self->{Store}->{Response}->content() =~ m/form[^>]*action="([^"]*)"/) {
        $dummy = $1
      }
    }
    Trace->Trc('I', 4, 0x02204, 'Action', defined($dummy) ? $dummy : 'not found');


    Trace->Trc('I', 5, 0x02204, 'Content',     defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->decoded_content() : '-');
    if (defined($self->{Store}->{Response}) && !$self->{Store}->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a200, $self->{Store}->{Response}->status_line(), 'Login'); 
    }
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  # Explizite Uebergabe des Returncodes noetig, da sonst ein Fehler auftritt
  return $rc;
}


sub getData {
  #################################################################
  #     Datenabruf
  #     Proc 3
  my $self = shift;

  my $merker          = $self->{subroutine};
  $self->{subroutine} = (caller(0))[3];
  Trace->Trc('S', 2, 0x00001, $self->{subroutine}, CmdLine->argument(0));
  
  my $rc = 0;

  if ($self->{Store}->{Location}->{Last} eq 'Data') {
    Trace->Trc('I', 2, 0x02301);
    # Das waere einfacher, aber es werden keine freundlichen Robots reingelassen
    # $self->{Browser}->delay($self->{Store}->{Location}->{Data}->{Delay}/60);
    $self->myGet('Data');
  } else {
    Trace->Trc('I', 4, 0x02300, $self->{Store}->{Location}->{Last} || 'Neustart', 'Data');
    $self->{Store}->{Location}->{Last} = 'Data';
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  }
  
  if (defined($self->{Store}->{Response}) &&
      $self->{Store}->{Response}->is_success && 
      $self->{Store}->{Response}->header('title') =~ /$self->{Store}->{Location}->{Data}->{Title}/) {
    Trace->Trc('I', 1, 0x0230a, $self->{Store}->{Response}->status_line(), 'Data');
    Trace->Trc('I', 4, 0x02303, $self->{Store}->{Response}->status_line());
 
    # Auswertung der Daten
    my %signal;
    my $content = $self->{Store}->{Response}->decoded_content();
    open IN, '<', \$content or die $!;
    while (<IN>) {
      my $line = $_;
      while ((my $key, my $value) = each(%{$self->{Store}->{Location}->{Data}->{Field}})) {
        if ($line =~ /$value/) {
          $signal{$key} = decode_entities($1);
          $signal{$key} =~ s/([^[:ascii:]]+)/unidecode($1)/ge;
        };
      }
    }
    close(IN);

    # Verlgeich mit dem alten Signal
    if (!defined($self->{Store}->{Signal}->{ID}) || ($self->{Store}->{Signal}->{ID} ne $signal{ID})) {
      my $firstsignal;
      if (!defined($self->{Store}->{Signal}->{ID})) {
        print "Erstsignal\n";
        my $firstsignal = 1;
      } else {
        print "Neues Signal\n";
      }
      undef($self->{Store}->{Signal});
      while ((my $key, my $value) = each %signal) {$self->{Store}->{Signal}->{$key} = $value}  
      if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}};
      Trace->Trc('I', 1, 0x02310, "  ID:                " . $self->{Store}->{Signal}->{ID});
      Trace->Trc('I', 1, 0x02310, "  Signal:            " . $self->{Store}->{Signal}->{Signal});
      Trace->Trc('I', 1, 0x02310, "  Stand:             " . $self->{Store}->{Signal}->{Stand});
      Trace->Trc('I', 1, 0x02310, "  Zeit:              " . $self->{Store}->{Signal}->{Zeit});
      Trace->Trc('I', 1, 0x02310, "  Stopp-Loss-Marke:  " . $self->{Store}->{Signal}->{SL});
      Trace->Trc('I', 1, 0x02310, "  Take-Profit_Marke: " . $self->{Store}->{Signal}->{TP});

      my ($dd, $mon, $yy, $hh, $mm) = ($self->{Store}->{Signal}->{Zeit} =~ /(\d+)\.(\d+)\.(\d+).*?(\d+):(\d+)/);
      

      open my $fh, '>', '/home/fxrun/var/lib/fxassist/htdocs/start-signal.csv';
      print $fh $self->{Store}->{Signal}->{Signal} . ';' . $self->{Store}->{Signal}->{Stand} . ';' . $self->{Store}->{Signal}->{SL} . ';' . $self->{Store}->{Signal}->{TP} . ';' . $yy . ';' . $mon . ';' . $dd . ';' . $hh . ';' . $mm . "\r\n";
      close $fh;
      open my $fh, '>', '/home/fxrun/var/lib/fxassist/htdocs/start-signal-uk.csv';
      print $fh $self->{Store}->{Signal}->{Signal} . ';' . $self->{Store}->{Signal}->{Stand} . ';' . $self->{Store}->{Signal}->{SL} . ';' . $self->{Store}->{Signal}->{TP} . ';' . $yy . ';' . $mon . ';' . $dd . ';' . $hh - 1 . ';' . $mm . "\r\n";
      close $fh;


      if (! $firstsignal) {
          my $event = $self->{Store}->{Signal}->{Signal} . ' @' . $self->{Store}->{Signal}->{Stand};
          my $description =  'SL: ' . $self->{Store}->{Signal}->{SL} . '; TP: ' . $self->{Store}->{Signal}->{TP} . '; ' . $self->{Store}->{Signal}->{Zeit};
          $event =~ tr/a-zA-Z0-9@.-:; //cd;
          $description =~ tr/a-zA-Z0-9@.\-:; //cd;
          foreach my $user ('mbartosch', 'pkempf', 'aleibl', 'mschiffner') {
              `prowlnotify --recipient $user --application FxAssist --event "$event" --description "$description"`;
          }
	  foreach my $apikey ('738585db5467b88f162765c2798dbb4f6847a1d961b0cd33', '931241427ac46b657cc26d58860f69a6552da0f7ef1ede94', '18c0a7b7ae2d3e6ffedeee2ccf2d598659ddc02e009be2ad') {
              `nma -apikey=$apikey -application="FxAssist" -event="$event" -notification="$description"`;
          }
    } 
    }
  } else {
    $self->doDebug();
    if (defined($self->{Store}->{Response}) && !$self->{Store}->{Response}->is_success()) {
      Trace->Trc('I', 1, 0x0a300, $self->{Store}->{Response}->status_line(), 'Login'); 
    }
    Trace->Trc('I', 4, 0x02304, 'Status',      defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->status_line() : 'Neustart oder undefinierter Fehler');
    Trace->Trc('I', 4, 0x02304, 'Title',       defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->header('title') : 'Response nicht definiert.');
    Trace->Trc('I', 4, 0x02304, 'Success',     defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_success() ? 'yes' : 'no'  : '-');
    Trace->Trc('I', 4, 0x02304, 'Redirection', defined($self->{Store}->{Response}) ? $self->{Store}->{Response}->is_redirect() ? 'yes' : 'no' : '-');
    $self->{Store}->{Location}->{Next} = 'Login';
    if ($self->{Storable}) {eval {store \$self->{Store}, $self->{Storable}}}
  }

  Trace->Trc('S', 2, 0x00002, $self->{subroutine});
  $self->{subroutine} = $merker;

  # Explizite Uebergabe des Returncodes noetig, da sonst ein Fehler auftritt
  return $rc;
}


1;
