package Examples;
# Packetname der mit "use" oder "Plugin=" eingebunden wird
use 5.004;
use strict;

# Liste der exportierten Funktionen
# Dies ist nur nötig, wenn man auf das explizite Benennen des Packages
# beim Einbinden in der pft.ini verzichtet will
# Bsp.: out_aktion=Plugin::simple statt Out_aktion=Plugin::Examples:simple
# Nicht empfehlenswert, da unuebersichtlich und ein Refresh der Module nicht
# mehr moeglich ist.

#use base 'Exporter';
#our @EXPORT = qw(simple normal complex);
#our @EXPORT_OK = ();
#use vars @EXPORT, @EXPORT_OK;

$| = 1;
use IPC::Open3;
local (*IN, *OUT, *ERR);
use Fcntl;

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

BEGIN {
  
  # Persistente Variablen
  my %perHandle;
  my %options = (create    => 1,
                 exclusive => 0,
                 mode      => 0644,
                 destroy   => 0);

  #-------------------------------------------------------------
  # Anfang des Anwendungscodes
  # Definition persistenter Variablen
  #------------------------------------------------------------- 

  # I Ohne Shared Memory nur verwenden bei synchroner Verarbeitung
  # my $counter = 0;

  # II IPC::Shareable
  # my $counter;
  # $perHandle{counter} = tie $counter, 'IPC::Shareable', 'counter', {%options};
  # $perHandle{counter}->shlock(LOCK_EX);
  # $counter = 1000 if (!defined($counter));
  # $perHandle{hash}->shunlock();

  # III IPC::Shareable fuer Hashes
  # my %hash = ();
  # my $_hash = '';
  # $perHandle{hash} = tie $_hash, 'IPC::Shareable', 'hash', {%options};
  #  
  # $perHandle{hash}->shlock(LOCK_EX);
  # if (defined($_hash)) {(%hash) = thaw $_hash} else {$_hash = freeze %hash}
  # $perHandle{hash}->shunlock();

  # IV Mittels IPC::ShareLite
  # $perHandle{counter} = IPC::ShareLite->new(-key     => 'counter',
  #                                           -create  => 'yes',
  #                                           -destroy => 'no') or die $!;
  # $perHandle{counter}->store(my $counter);

  #-------------------------------------------------------------
  # Ende des Anwendungscodes
  # Definition persistenter Variablen
  #------------------------------------------------------------- 


  sub cleanup() {
    #################################################################
    # sub Cleanup Shared Momory
    #
    while ((my $k, my $v) = each %perHandle) {$v->remove()}
  }


  #-------------------------------------------------------------
  # Anfang des Anwendungsproceduren
  #------------------------------------------------------------- 

  sub simple {
    #################################################################
    # sub simple
    #

    my ($stdout, $stderr, $stdin) = (shift, shift, shift);
    my $rc = 0;
    my $sigsave = $SIG{CHLD} || 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    #-------------------------------------------------------------
    # Anfang des Anwendungscode 
    #------------------------------------------------------------- 
    my $sleep = shift || 1;

    # Alternative Zugriffsmethoden auf persistente Variablen
    #
    # I
    # $counter++;

    # II
    # $perHandle{counter}->shlock(LOCK_EX);
    # $counter++;
    # $perHandle{counter}->shunlock();

    # III
    # $perHandle{fhhash}->shlock(LOCK_EX);
    # (%hash) = thaw $_hash;
    # if (!defined($hash{$file})) {
    # $hash{key} = 'value';
    # $_hash = freeze %hash;
    # $perHandle{hash}->shunlock();

    # IV
    # $perHandle{counter}->lock(LOCK_EX);
    # $counter = $perHandle{counter}->fetch();
    # $counter++;
    # $perHandle{counter}->store($counter);
    # $perHandle{counter}->unlock;

    open (OUT, ">>/tmp/pgk");
    print OUT $$ . ": Ich bin sehr simpel!\n";
    close OUT;

    # open (OUT, ">>/tmp/pgk");
    # print OUT $$ . ": Ich bin sehr simpel!\n";
    # close OUT;
    # sysopen(OUT, "/tmp/pgk", O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK);
    # syswrite(OUT, $$ . ": Ich bin sehr simpel!\n");
    # close OUT;

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
}

1;
