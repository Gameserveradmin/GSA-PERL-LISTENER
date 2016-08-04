#!/usr/bin/perl -w

use English;
use strict;
use IO::Socket;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use Config::Abstract::Ini;
use File::Basename;
use Cwd qw/abs_path/;
use MIME::Base64;
# Gameserveradmin Listener
#
# Version 0.3.1
# Copyright Tobias Schäfer <tobi.schaefer@gmail.com>
# For additional informations see http://www.gameserveradmin.de/interface/

print "\n";
print_to_console("Starting Gameserveradmin listener v. 0.3.2");
my $dir = dirname(abs_path($0));

our $ip = '';


# Load settings from ini file
my $inifile = "$dir/games.ini";
my $settings = new Config::Abstract::Ini($inifile);
my $port = $settings->get_entry_setting('global', 'port');
my $loginpasswd = $settings->get_entry_setting('global', 'password');
print_to_console("Settings from $inifile loaded");

if($port eq "")
{
	print_to_console("ERROR (No port set in games.ini)");
	exit;
}
if($loginpasswd eq "")
{
	print_to_console("ERROR (No password set in games.ini)");
	exit;
}

if(!-e "$dir/cache") 
{
	print_to_console("ERROR (Cache dir '$dir/cache' not exist or not writeable)");
	exit;	
}

sleep(3);

my $socket = new IO::Socket::INET (
    LocalPort => $port,
    Listen    => 1,
    Proto     => 'tcp',
    Reuse     => 1
) || die "$!\n";

print_to_console("Gameserveradmin listener started on port: $port\n");


my %clients;

while(  )
{
	my($client, $client_addr) = $socket->accept();
	my ($cport, $caddr) = sockaddr_in($client_addr);
	$ip = inet_ntoa($caddr);

	$client->recv(my $string, 10485760); # recive max. 10 MB
	my @part = split("\x00", $string);
	my $seed = $part[1];
	my $game = $part[2];
	my $command = $part[3];
	my $data = $part[4];

	print_to_console("R: $string");

	my $digest = md5_hex($loginpasswd);
	if($part[0] ne $digest)
	{ 
		print_to_console("Login fail");
		$client->send("Login fail\n");
	}
	elsif(($command ne "hello") && ($seed ne $clients{$ip}))
	{
		print_to_console("wrong seed $seed");
		#$client->send("wrong seed $seed\n");
		$client->send("\n");
	}
	else
	{
		my $gameserver = new gameserver($game);
		switch_command: {
            $command eq "hello" && do
			{
				
				if(!defined($clients{$ip}))
				{
					%clients = ($ip => sprintf ('%05d',int(rand(99999))),);
				}
				#print_to_console("send seed: $clients{$ip}");
				$client->send("$clients{$ip}\n");
				last switch_command;
			};
            $command eq "serverlist" && do
			{
				$gameserver->reload_ini();
				my $server_list = $gameserver->server_list();
				print_to_console("Recived command: serverlist");	
				$client->send("$server_list");
				last switch_command;
			};
            $command eq "info" && do
			{
				my $info = $gameserver->server_info();
				print_to_console("$game: Recived command: info");	
				$client->send("$info");
				last switch_command;
			};
            $command eq "stop" && do
			{
				if($gameserver->server_stop())
				{
					print_to_console("$game: Recived command: stop");
					$client->send("stopping server\n");
				}
				last switch_command;
			};
            $command eq "start" && do
			{
				if($gameserver->server_start())
				{
					print_to_console("$game: Recived command: start");
					$client->send("starting server\n");
				}
				last switch_command;
			};
            $command eq "get_config" && do
			{
				if(my $config = $gameserver->get_config())
				{
					print_to_console("$game: Recived command: get_config");
					$client->send($config);
				}
				last switch_command;
			};
            $command eq "get_log" && do
			{
				if(my $log = $gameserver->get_log())
				{
					print_to_console("$game: Recived command: get_log");
					$client->send("$log\n");
				}
				last switch_command;
			};
            $command eq "delete_log" && do
			{
				if(my $log = $gameserver->delete_log())
				{
					print_to_console("$game: log deleted");
					$client->send("delete log\n");
				}
				last switch_command;
			};
            $command eq "update_config" && do
			{
				if(my $log = $gameserver->update_config($data))
				{
					print_to_console("$game: config updated");
					$client->send("$game: config updated\n");
				}
				last switch_command;
			};
			do 
			{ 
				print_to_console("ERROR (unkonown command \"$command\")");
				last switch_command;
			}
		}
	} 
	close $client;
}
close $socket;



sub print_to_console
{
	my $message = shift;
	my $time = get_time();
	my $remote = (defined($ip) && ($ip ne ''))  ? " - $ip" : '';
	print "$time$remote - $message\n";
	open(FILE, ">>$port.log");
	print FILE "$time$remote - $message\n";
	close FILE;
}


sub get_time
{
	my ($sec, $min, $h, $d, $m, $y) = localtime(time);
	$y+=1900;
	my @list = qw( 1 2 3 4 5 6 7 8 9 10 11 12 ); 
	return sprintf('%02d', $d) . "." . sprintf('%02d',$list[$m]) . "." . $y . " " . sprintf('%02d', $h) . ":" . sprintf('%02d', $min) . ":" . sprintf('%02d', $sec);
}


package gameserver;

	my $server_id = '';

	sub new 
	{
		my $Objekt = shift;
		$server_id = shift;

		my $Referenz = {};
		bless($Referenz,$Objekt);
		return($Referenz);
	}
	
	#	List all Gameservers 
	#	@return		string	$server
	#
	sub server_list
	{
		my %allserver = $settings->get_all_settings;
		my $server = '';

		while((my $key, my $value) = each(%allserver))
		{
			if($key ne 'global')
			{
				my $name = $settings->get_entry_setting($key, 'name');
				my $gameid = $settings->get_entry_setting($key, 'game');
				my $gameport = $settings->get_entry_setting($key, 'port');
				my $status = _get_status($key);
				$name = defined($name) ? $name : '';
				$server = "$server$key\x00$name\x00$gameid\x00$gameport\x00$status\n";
			}
		}
		return $server;
	}

	#	Get info for a gameserver
	#	@return		string	$info
	#
	sub server_info
	{
		my $description = $settings->get_entry_setting($server_id, 'description');
		my $query_port = $settings->get_entry_setting($server_id, 'query_port');
		my $config_file = $settings->get_entry_setting($server_id, 'config_file');
		my $log_file = $settings->get_entry_setting($server_id, 'log_file');
		my $rcon_pw = $settings->get_entry_setting($server_id, 'rcon_pw');
		my $rcon_user = $settings->get_entry_setting($server_id, 'rcon_user');
		my $rcon_port = $settings->get_entry_setting($server_id, 'rcon_port');
		my $edit_files = $settings->get_entry_setting($server_id, 'edit_files');

		$description = defined($description) ? $description : '';
		$query_port = defined($query_port) ? $query_port : '';
		$config_file = defined($config_file) ? $config_file : '';
		$log_file = defined($log_file) ? $log_file : '';
		$rcon_pw = defined($rcon_pw) ? $rcon_pw : '';
		$rcon_user = defined($rcon_user) ? $rcon_user : '';
		$rcon_port = defined($rcon_port) ? $rcon_port : '';
		$edit_files = defined($edit_files) ? $edit_files : '';


#my @vars = ('query_port','config_file','log_file','rcon_pw','rcon_user','rcon_port','edit_files');
#my %data;
#foreach (@vars) {
#	 %data = ($_ => defined($settings->get_entry_setting($server_id, $_)) ? $settings->get_entry_setting($server_id, $_) : '');
#	print $_ . "\n";
#}
#print "$data{'query_port'}";

	
		my $info = "$server_id\x00" . 										# 0 	Server ID
			$settings->get_entry_setting($server_id, 'name') . "\x00" . 	# 1 	Name
			$description . "\x00" . 										# 2 	Description
			$settings->get_entry_setting($server_id, 'game') . "\x00" .		# 3 	Game 
			$settings->get_entry_setting($server_id, 'port') . "\x00" . 	# 4 	Port 
			$query_port . "\x00" . 											# 5 	Query Port 
			_get_status($server_id) . "\x00" . 								# 6 	Status UP or DOWN
			_read_file("$dir/cache/$server_id") . "\x00" . 					# 7		Time started
			$config_file . "\x00" . 										# 8 	Path to config
			$log_file . "\x00" .  											# 9 	Path to log
			$rcon_pw . "\x00" .  											# 10 	RCON PW
			$rcon_user . "\x00" .   										# 11	RCON user
			$rcon_port . "\x00" .   										# 12	RCON port
			$edit_files . "\n";   											# 13
		return $info;
	}


	sub server_start
	{
		my $deamon = $settings->get_entry_setting($server_id, 'deamon');
		my $params = defined($settings->get_entry_setting($server_id, 'params')) ? $settings->get_entry_setting($server_id, 'params') : '';
		my $path = $settings->get_entry_setting($server_id, 'path');

		my $status = ` screen -ls |grep -wq $server_id && echo \"UP\" || echo \"DOWN\"`;
		if($status eq "DOWN\n")
		{
			print "cd $path\n screen -d -m -S $server_id ./$deamon $params";
			`cd $path\n screen -d -m -S $server_id ./$deamon $params`;
			open(DATEI, ">$dir/cache/$server_id");
			print DATEI  time();
			close DATEI;
			return 1;
		}
	}

	sub server_stop
	{
		system("kill \`screen -ls |grep $server_id |awk -F . '{print \$1}'|awk '{print \$1}'\`");
		return 1;
	}

	sub get_config
	{
		my $config_file = $settings->get_entry_setting($server_id, 'config_file');
		my $config = _read_file($config_file);
		return $config;
	}

	sub get_log
	{
		my $log_file = $settings->get_entry_setting($server_id, 'log_file');

		if(-d $log_file)
		{
			opendir(DIR, $log_file);
			my @Dateien = readdir(DIR);
			my $log = '';
			foreach(@Dateien) 
			{
				$log = $log . _read_file($log_file . $_);
			}

			return $log;
		}
		if(-f $log_file) 
		{
			my $log = _read_file($log_file);
			return $log;
		}

	}

	sub delete_log
	{
		my $log_file = $settings->get_entry_setting($server_id, 'log_file');
		if(-d $log_file)
		{
			opendir(DIR, $log_file);
			my @Dateien = readdir(DIR);
			foreach(@Dateien) 
			{
				unlink("$log_file$_");
			}
		}
		if(-f $log_file) 
		{
			unlink($log_file);
		}
		return 1;
	}

	sub update_config
	{
		my $Objekt = shift;
		my $data = shift;
		my $config_file = $settings->get_entry_setting($server_id, 'config_file');
		open(FILE, ">$config_file");
		print FILE $data;
		close FILE;
		return $data;
	}


	sub reload_ini
	{
		$settings = new Config::Abstract::Ini($inifile);
	}



	sub _read_file
	{
		my $file = shift;
		my $data = '';
		if(-e $file) 
		{
			open (FILE, $file) or die $!;
			while(<FILE>)
			{
				$data = $data . $_;
			}
			close (FILE);
			return $data;
		}
	}

	sub _get_status
	{
		my $game = shift;
		my $status = ` screen -ls |grep -wq $game && echo \"UP\" || echo \"DOWN\"`;
		if($status eq "UP\n")
		{
			$status = "UP";
		}
		else
		{
			$status = "DOWN";
		}
		return($status);
	}
1;
