package ExamplesOO;
# Packetname der mit "use" oder "Plugin=" eingebunden wird
use 5.004;
use strict;

$| = 1;
use IPC::Open3;
local (*IN, *OUT, *ERR);
use Fcntl;
use FileHandle;

# use IPC::Shareable qw(:lock);
# use IPC::ShareLite qw(:lock);
# use FreezeThaw qw(freeze thaw cpmStr saveFreeze cmpStrHard);

#################################################################
# Anwendungsprozeduren:
#
# Deklaration: Aufnahme in our @EXPORT = qw(...
#
# Definition: sub <Funktionsname>
#
#   Eingabe: 
#    - generisch: $self 
#    - generisch: Pointer auf Standardausgabe der Funktion (STDOUT)
#    - generisch: Pointer auf Fehlerausgabe der Funktion (STDERR)
#    - generisch: Pointer auf Standardeingabe der Funtkion (STDIN)
#    - aus der pft.ini: Beliebige weitere Parameter
#
#   Ausgabe:
#    - Returncode der Funktion
#      Ein Returncode von 0 wird vom Steuerprogramm als Erfolg 
#      gewertet. Alle anderen Retorncodes als Fehler
#################################################################

#-------------------------------------------------------------
# Anfang des Anwendungsproceduren
#------------------------------------------------------------- 

sub new() {
  #################################################################
  # sub Instantiieren: Aufruf
  #
  my $class = shift;
  my $self = {};
  bless $self, $class;
    
  # Initialisierung

  my %var = %{(shift)};
  $self->{VAR} = \%var;

  my $dummy;
  my %prot;
  foreach (keys %var) {
    if (/^Prot:(.+)$/) {
      $dummy = $prot{$1}  = new FileHandle "$var{$_}", O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK;
      autoflush $dummy if ($dummy);
    }
  }  
  $self->{PROT} = \%prot;

  return $self;
}


sub DESTROY() {
  #################################################################
  # sub Instantiieren: Aufruf
  #
  my $self = shift;

  my $fh;
  
  foreach (keys %{$self->{PROT}}) {
    $fh =  $self->{PROT}{$_};
    eval {close $fh}
  }
}


sub simple {
  #################################################################
  # sub simple
  #
  # Erwartet wird folgende oder eine aehnliche ini Datei
  #
  # [Prg]
  # Plugin = ExamplesOO
  #
  # [ExamplesOO]
  # Prot:Protokollfile = /tmp/pgk
  # 
  # ....
  # 
  # [Partner Testpartner]
  # out_ok_aktion=Plugin::ExamplesOO->simple Protokollfile "Dies ist der zu protokollierende Text mit Variablen %SENDER% %STATUS%
  #
  # Alternative Syntax:
  # out_ok_aktion=Plugin::ExamplesOO::simple Protokollfile "Dies ist der zu protokollierende Text mit Variablen %SENDER% %STATUS%
  #

  my $self = shift;

  my ($stdout, $stderr, $stdin) = (shift, shift, shift);
  my $rc = 0;
  my $sigsave = $SIG{CHLD} || 'DEFAULT';
  $SIG{CHLD} = 'DEFAULT';

  #-------------------------------------------------------------
  # Anfang des Anwendungscode 
  #------------------------------------------------------------- 
  my $protfile = shift;
  my $prothandle =  $self->{PROT}{$protfile};
  print $prothandle "$$:@_:\n"  || return 2;

  #-------------------------------------------------------------
  # Ende des Anwendungscodes
  # Rueckgabe des Returncodes $rc 
  #------------------------------------------------------------- 
  $SIG{CHLD} = $sigsave;
  return $rc
}


sub normal {
  #################################################################
  # sub normal
  #
  my $self = shift;

  my ($stdout, $stderr, $stdin) = (shift, shift, shift);
  my $rc = 0;
  my $sigsave = $SIG{CHLD} || 'DEFAULT';
  $SIG{CHLD} = 'DEFAULT';

  #-------------------------------------------------------------
  # Anfang des Anwendungscode 
  #------------------------------------------------------------- 

  print "Ich bin normal!\n";

  # Kommando definieren
  my $cmd = "ls -al";

  # Kommandokanaele oeffnen  
  my $childpid = open3(*IN, *OUT, *ERR, $cmd);

  close IN; 
  my @stdout = <OUT>;
  close OUT;
  close ERR;

  open (OUT, '>>/tmp/pgk');
  foreach (@stdout) {print OUT "$_\n"}
  close OUT;

  # Warten bis das Kommando terminiert
  waitpid($childpid, 0);
  $rc = $?;

  # Returncode, Signalhandler und Coredump ermitteln
  $rc  = $rc >> 8;

  #-------------------------------------------------------------
  # Ende des Anwendungscodes
  # Rueckgabe des Returncodes $rc 
  #------------------------------------------------------------- 
  $SIG{CHLD} = $sigsave;
  return $rc
}


sub complex {
  #################################################################
  # sub complex
  #
  my $self = shift;

  my ($stdout, $stderr, $stdin) = (shift, shift, shift);
  my $rc = 0;
  my $sigsave = $SIG{CHLD} || 'DEFAULT';
  $SIG{CHLD} = 'DEFAULT';

  @$stdout = ();
  @$stderr = ();

  #-------------------------------------------------------------
  # Anfang des Anwendungscode 
  # @stdout, @stderr und $rc befuellt
  #------------------------------------------------------------- 

  # Kommando definieren
  # my $cmd = 'ls';
  # Argumente definieren
  # my @args = ('-al');
  # entweder getrennt oder alternativ zusammen:
  my $cmd = "ls -al";
  my @args = ();
  # my $cmd = "cut -d'.' -f1";

  # Kommandokanaele oeffnen  
  my $childpid = open3(*IN, *OUT, *ERR, $cmd, @args);

  # Ggf. das Kommando mit eingaben fuettern
  foreach (@$stdin) {print IN "$_\n"}
  close IN; 

  # Ausgabe und Fehlerkanal auslesen
  @$stdout = <OUT>;
  @$stderr = <ERR>;
  close OUT;
  close ERR;

  # Warten bis das Kommando terminiert
  waitpid($childpid, 0);
  $rc = $?;

  # Returncode, Signalhandler und Coredump ermitteln
  my $exit_value  = $rc >> 8;
  my $signal_num  = $rc & 127;
  my $dumped_core = $rc & 128;

  $rc = $exit_value;

  #-------------------------------------------------------------
  # Ende des Anwendungscodes
  # Rueckgabe des Returncodes $rc 
  #------------------------------------------------------------- 
  $SIG{CHLD} = $sigsave;
  return $rc
}

#-------------------------------------------------------------
# Ende des Anwendungsproceduren
#------------------------------------------------------------- 

1;
