#!/usr/bin/perl
use strict;
use warnings;
use Mail::IMAPClient;
use IO::Socket::SSL;
use Net::SMTPS;

my $imap_server = '';
my $imap_port = '';
my $imap_user = '';
my $imap_password = '';
my $imap_folder = 'INBOX';
my $imap_search_term = 'Signal';

my $smtp_server = '';
my $smtp_port = '';
my $smtp_user = '';
my $smtp_password = '';
my $smtp_mail_from = '';
my $smtp_mail_from_name = 'mail-helper';
#must be converted to an array:
my $smtp_recipients = 'mail1@example.com';
my $smtps_client;

my $socket = IO::Socket::SSL->new (PeerAddr => $imap_server, PeerPort => $imap_port) or die "Socket(): $@";
my $imap_client = Mail::IMAPClient->new(Socket => $socket, User => $imap_user, Password => $imap_password) or die "New(): $@";

if($imap_client->IsAuthenticated() != 1) #Authentication failed
{
	print "Could not login to Imap server. Please check credentials.\n";
	exit;
}
else #Authentication was sucessfully, continue with script
{
	if($imap_client->selectable($imap_folder) == 1) #Specified folder is selectbale, continu with script
	{
		#Select folder where the desired mails are stored
		$imap_client->select($imap_folder);

		#Search for mails which we are interested in
		my @search_results = $imap_client->search("UNSEEN SUBJECT ".$imap_search_term);

		#If mails were found process them...
		if(@search_results > 0)
		{
			my $message_item;

			foreach $message_item (@search_results)
			{
				my $mail_subject = $imap_client->subject($message_item);
				my $mail_body = $imap_client->body_string($message_item);

				my $smtps = Net::SMTPS->new($smtp_server, Port => $smtp_port, doSSL => 'starttls')
					or warn "$!\n";

				defined($smtps->auth($smtp_user, $smtp_password))
					or die "Could not authenticate to SMTP server: $!\n";

				$smtps->mail($smtp_mail_from);
				$smtps->to('mail1\@exmaple.com');
				$smtps->recipient($smtp_recipients);
				$smtps->data();
				$smtps->datasend("To: mail1\@example.com\n");
				$smtps->datasend("From: $smtp_mail_from_name\n");
				$smtps->datasend("Subject: $mail_subject\n\n");
				$smtps->datasend("$mail_body\n");
				$smtps->dataend();
				$smtps->quit();
			}
			
			#Set message flags to unseen to ignore them at the next run
			#$imap_client->set_flag("Seen", @search_results);
		}
	}
	else #Specified folder is not selectable, shutting down the script
	{
		print "Cannot open specified IMAP folder. Shutting down...\n";
		$imap_client->logout();
		exit;
	}
}

$imap_client->logout();