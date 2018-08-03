#!/usr/bin/perl
#Editor=Wide load 4:  Set your wide load editor to 4 column tabs, fixed size font.  Suggest Kate (Linux) or Notepad++ (windows).

use strict;
use warnings;


use Getopt::Long 	qw(:config no_ignore_case);		# Extended processing of command line options - ?? where is this called

use Data::Dumper;									# stringified perl data structures, suitable for both printing and eval

use File::Path 		qw(make_path);					# Create or remove directory trees


my $dialog;			# A place to install UI::Dialog when it gets loaded (required below) in checkDependencies subroutine
my %bin;			# ???

my %dependencies = (
#devices:
    'udevadm' 			=> 'udev',					# Dynamic    device management (device events and status information)
    'blockdev' 			=> 'util-linux',			# call block device ioctls from the command line
    'blkid' 			=> 'util-linux',			# Get  block device information and list of any partitions

    'dd' 				=> 'coreutils',				# Linux convert and copy (disk destroyer)
    
    'flash_erase' 		=> 'mtd-utils',				# Use to restore flash drives (Memory Technology Devices [drivers for flash types of memory])
    
#partitions:
    'sfdisk' 			=> 'sfdisk',				# Gets/Sets partion maps
    
    'fsarchiver' 		=> 'fsarchiver',			# Partion dumper for ext file systems
    
    'partclone.vfat' 	=> 'partclone',				# clone and restore a partition
    'partclone.btrfs' 	=> 'partclone',				# clone and restore a partition
    'partclone.info' 	=> 'partclone',				# image show 	- show image head information
    'partclone.restore' => 'partclone',				# image restore	- restore partclone image to device
    
    'partprobe' 		=> 'parted',				# inform the OS of partition table changes
    
    'umount' 			=> 'mount',					#
    'mount' 			=> 'mount'					#
);


my $logfile = '/var/log/odroid-backup.log';


# --- Get OPTIONS -----------------------------------------------------------------------------------------------------------------
my %options = ();
GetOptions(\%options, 'help|h', 'allDisks|a', "ASCII|A", 'text|t', 'backup', 'restore', 'disk=s', 'partitions=s', 'directory=s');
if(defined $options{help}){
    print "Odroid Backup program\n
Usage $0 options
Options

--help|-h       Print this message

--allDisks|-a   Display all disks in the selector (by default only removable disks are shown)

--text|-t       Force rendering with dialog even if zenity is available
--ASCII|-A		Force rendering with ASCII

--backup    	Do a backup
--restore   	Do a restore

--disk      	Disk to backup/restore to (e.g.: sda, sdb, mmcblk0, mmcblk1, etc)

--partitions 	List of partitions to backup/restore. Valid names are in this format:
					bootloader,mbr,/dev/sdd1 -- when backuping
					bootloader,mbr,1 -- when restoring
					
--directory 	Directory to backup to or to restore from
";
    exit 0;
}


#validate the command-line options supplied that have mandatory arguments
foreach my $switch ('disk','partitions','directory'){
    if(defined $options{$switch} && $options{$switch} eq ''){
        die "Command-line option $switch requires an argument";
    }
}


# --- determine if we're going to run only with command-line parameters, or if we need GUI elements as well ------------
my $cmdlineOnly = 0;
if((defined $options{backup} || defined $options{restore}) && defined $options{disk} && defined $options{partitions} && defined $options{directory}){ $cmdlineOnly = 1; }


# --- Check and warm ---------------------------------------------------------------------------------------------------
checkDependencies();
checkRootUser();
firstTimeWarning();


# --- Create a human conversion tool -----------------------------------------------------------------------------------
my $human = Number::Bytes::Human->new(bs => 1024, si => 1);


# --- Decide what to do ------------------------------------------------------------------------------------------------
my $mainOperation;
if(defined $options{'backup'} || defined $options{'restore'}){

    if(defined $options{'backup'} && defined $options{'restore'}){ die("Error: Both backup and restore options were specified, which is ambiguous."); }

    if(defined $options{'backup' }								){ $mainOperation = 'backup' ; }
    if(defined $options{'restore'}								){ $mainOperation = 'restore'; }
    
}
else {
	# https://i.imgur.com/m3Pr1NM.png
    $mainOperation = $dialog->radiolist(
		title	=> "Odroid Backup - Please select if you want to perform a backup or a restore:", 
		text	=> "Please select if you want to perform a backup or a restore:",
        list    => [ 'backup' , [  'Backup partitions', 1 ],
					 'restore', [ 'Restore partitions', 0 ] ]
	);

    print "$mainOperation\n";
}

my $error = 0;



# === BACKUP ======================================================================================
if($mainOperation eq 'backup'){
    
    my %disks = getRemovableDisks();		#get a list of removable drives (or all drives if so desired)
    
    # === Get or choose a disk =======================
    # --- convert the disks hash to an array the way radiolist expects
    my @displayedDisks = ();
    foreach my $disk (sort keys %disks){
        push @displayedDisks, $disk;
        my @content =  ( "$disks{$disk}{model}, $disks{$disk}{sizeHuman}, $disks{$disk}{removable}", 0 );
        push @displayedDisks, \@content;
    }
#   print Dumper(\@displayedDisks);														#TEST


    # --- create a radio dialog for the user to select the desired disk
    my $selectedDisk;
    if(defined $options{'disk'}){
        #validate if the user option is part of the disks we were going to display
        my $valid = 0;
        foreach my $disk (@displayedDisks){
            if($disk eq $options{'disk'}){
                $valid = 1;
                $selectedDisk = $options{'disk'};
            }
        }
        if(!$valid){ die "Disk $options{'disk'} is not a valid disk. Valid options are: ".join(" ", sort keys %disks); }
    }
    else{
				$selectedDisk = $dialog->radiolist(
					title 	=> "Odroid backup - Please select the disk you wish to backup", 
					text 	=> "Please select the disk you wish to backup",
					list 	=> \@displayedDisks);
    }
#   print $selectedDisk;																#TEST

	
	# --- 
    if($selectedDisk){
    
        if($selectedDisk=~/mtd/){				#mtd -- A Memory Technology Device is a type of device file in Linux for interacting with flash memory.
            #this is a flash device, use dd to back it up
            
            # - get directory path to use
            my $directory;
            if(defined $options{'directory'}) 	{ $directory = $options{'directory'};			}				# Set by option, or
            else								{ $directory = $dialog->dselect('path' => "."); }				# Ask for it
            print $directory;
            
            # - backup to given directory
            if ($directory) {
                
                if (!-d "$directory") { make_path($directory); }												#the directory might not exist. Test if it exists or create it
                
				# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
				# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
				`echo "Starting backup process (for flash memory device)"					>  $logfile`;		#truncate log
                `echo "\n*** Starting to backup ***" 										>> $logfile`;		#log something

                `$bin{dd}  if=/dev/$selectedDisk  of="$directory/flash_$selectedDisk.bin"  	>> $logfile 2>&1`;	# dd
                $error = $? >> 8;  `echo "Error code: $error" 								>> $logfile 2>&1`;	# right shift error code??

                my $size = -s "$directory/flash_$selectedDisk.bin";
                `echo "*** MTD $selectedDisk backup size: $size bytes ***" 					>> $logfile`;

                textbox("Odroid Backup status", $logfile);														#show backup status
                #backup is finished. Program will now exit.
            }
        }
        
        else {
			# === Show partions and select one ===============
            my %partitions = getPartitions($selectedDisk);														#get a list of partitions from the disk and their type
            print "Listing partitions on disk $selectedDisk...\n";
            print Dumper(\%partitions);

            #convert the partitions hash to an array the way checklist expects
            my @displayedPartitions = ();
            foreach my $part (sort keys %partitions) {
                push @displayedPartitions, $part;
                
                my $description = "";
                if (defined $partitions{$part}{label}) 			{ $description .= 								   "$partitions{$part}{label}, ";	}
                
																  $description .= 								   "$partitions{$part}{sizeHuman}, ";

                if (defined $partitions{$part}{literalType}) 	{ $description .= "$partitions{$part}{literalType} ($partitions{$part}{type}), "; 	}
                else 											{ $description .= 							  "type $partitions{$part}{type}, " ; 	}

                if (defined $partitions{$part}{mounted}) 		{ $description .= 						"mounted on $partitions{$part}{mounted}, ";	}

                if (defined $partitions{$part}{uuid}) 			{ $description .= 							  "UUID $partitions{$part}{uuid}, ";	}

																  $description .= 					  "start sector $partitions{$part}{start}";
																  
                my @content = ($description, 1);		#Convert from ? to ?
                push @displayedPartitions, \@content;
            }
            
            my @selectedPartitions;
            if(defined $options{'partitions'}){
                
                @selectedPartitions = split(',', $options{'partitions'});				#partitions should be a comma separated list - convert it to array
                
                #validate that the names proposed exist in the partition list to be displayed
                foreach my $partition (@selectedPartitions){
                    if(!defined $partitions{$partition}){ die "Partition $partition is not a valid selection. Valid options are: ". join(", ", sort keys %partitions); }
                }
            }
            
            else {
                #create a checkbox selector that allows users to select what they want to backup
                @selectedPartitions = $dialog->checklist(
					title	=> "Odroid backup - Please select the partitions you want to back-up", 
					text	=> "Please select the partitions you want to back-up",
                    list	=> \@displayedPartitions
				);
            }
            
            
            #remove an extra "$" being appended to the selected element sometimes by zenity
#           print "Partition list after select box: " . join(",", @selectedPartitions);	#TEST
            for (my $i = 0; $i < scalar(@selectedPartitions); $i++) {
                if ($selectedPartitions[$i] =~ /\$$/) {
                    $selectedPartitions[$i] =~ s/\$$//g;
                }
            }
            print "Using partition list: " . join(",", @selectedPartitions)."\n";

            
 			# === Backup selected partitons ==================
            if (scalar(@selectedPartitions) > 0 && $selectedPartitions[0] ne '0') {
            
                # - select a destination directory to dump to
                my $directory;
                if(defined $options{'directory'}) 	{ $directory = $options{'directory'};			}
                else 								{ $directory = $dialog->dselect('path' => ".");	}                
#               print $directory;														#TEST


                if ($directory) {
                    
                    if (!-d "$directory") { make_path($directory); }					#the directory might not exist. Test if it exists or create it
                   
                   
                    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                    `echo "Starting backup process (for non-flash memory device)"											>  $logfile`;	#truncate log

                    my $partitionCount 	= scalar(@selectedPartitions);
                    my $progressStep 	= int(100 / $partitionCount);					#For progress bar (fractiion of 100%)

					# - Backup each partition
                    foreach my $partition (reverse @selectedPartitions) {
                        
                        `echo "\n*** Starting to backup $partition ***" 													>> $logfile`;	#log something
                        
                        
                        # Start progress bar
                        if(!$cmdlineOnly) {
                            #if the backend supports it, display a simple progress bar
                            if (		$dialog->{'_ui_dialog'}->can('gauge_start')) {
										$dialog->{'_ui_dialog'}->gauge_start(
											title		=> "Odroid Backup", 
											text		=> "Performing backup...", 
											percentage	=> 1
										);
                            }
                        }
                        
                        
						# Backup mbr
						if ($partition eq 'mbr') {
                            #we use sfdisk to dump mbr + ebr
                            `$bin{sfdisk} -d /dev/$selectedDisk > '$directory/partition_table.txt'`;
                            $error = $? >> 8;	`echo "Error code: $error" 													>> $logfile 2>&1`;
															 `cat '$directory/partition_table.txt' 							>> $logfile 2>&1`;
															 
							# ProgressStep
                            if(!$cmdlineOnly) {
                                if (	$dialog->{'_ui_dialog'}->can('gauge_inc')) {
										$dialog->{'_ui_dialog'}->gauge_inc($progressStep);
										#sleep 5;
                                }
                            }
                        }
                        
                        # Backup bootloader
                        elsif ($partition eq 'bootloader') {
                            #we use dd to dump bootloader.  We dump the partition table as a binary, just to be safe.
                            `$bin{dd}  if=/dev/$selectedDisk  of="$directory/bootloader.bin"  bs=512 count=$partitions{bootloader}{end} >> $logfile 2>&1`;
                            $error = $? >> 8;	`echo "Error code: $error" 													>> $logfile 2>&1`;
                            my $size = -s "$directory/bootloader.bin";  `echo "*** Bootloader backup size: $size bytes ***" >> $logfile`;
                            
 							# ProgressStep
							if(!$cmdlineOnly) {
                                if (	$dialog->{'_ui_dialog'}->can('gauge_inc')) {
										$dialog->{'_ui_dialog'}->gauge_inc($progressStep);
										#sleep 5;
                                }
                            }
                        }
                        
                        else {
                            #Else a regular partition.  Based on the filesystem we dump it either with fsarchiver or partclone.
                            
                            # Get partition number
                            $partition =~ /([0-9]+)$/;
                            my $partitionNumber = $1;

                            
                            # dump vfat or btrfs filesystem: use partclone
                            if ($partitions{$partition}{literalType} eq 'vfat' || $partitions{$partition}{literalType} eq 'btrfs') {

                                # Partition can't be mounted while backing it up (eg. btrfs), so let's un-mount it
                                if(defined $partitions{$partition}{'mounted'}){
                                    `echo "Unmounting $partitions{$partition}{'mounted'}..."								>> $logfile`;
                                    `$bin{umount} $partition 																>> $logfile 2>&1`; 
                                }

                                my $partcloneVersion = 'partclone.' . $partitions{$partition}{literalType};
                                `echo "Using partclone binary: $partcloneVersion"											>> $logfile 2>&1`;
                                
                                `$bin{"$partcloneVersion"} -c -s $partition -o "$directory/partition_${partitionNumber}.img">> $logfile 2>&1`;		#the actual dump
                                $error = $? >> 8;	`echo "Error code: $error" 												>> $logfile 2>&1`;

                                #if the partition was umounted, it's nice to try to mount it back - to prevent other problems
                                if(defined $partitions{$partition}{'mounted'}){
                                    `echo "Mounting back $partitions{$partition}{'mounted'} (if it's in fstab)..." 			>> $logfile`;
                                    `$bin{mount} $partitions{$partition}{'mounted'}											>> $logfile 2>&1`;
                                }

                                `$bin{'partclone.info'} -s "$directory/partition_${partitionNumber}.img" 					>> $logfile 2>&1`;

								# ProgressStep
                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            
                            
                            # or dump ext filesystem: use fsarchiver
                            elsif ($partitions{$partition}{literalType} =~ /ext[234]/) {

                                `$bin{'fsarchiver'} -A savefs "$directory/partition_${partitionNumber}.fsa" $partition 		>> $logfile 2>&1`;		#the actual dump
                                $error = $? >> 8;	`echo "Error code: $error" 												>> $logfile 2>&1`;

                                `$bin{'fsarchiver'} archinfo  "$directory/partition_${partitionNumber}.fsa" 				>> $logfile 2>&1`;

 								# ProgressStep
                               if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            
                            
                            else {
                                messagebox("Odroid Backup error", "The partition $partition has a non-supported filesystem. Backup will skip it");
                                `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            
                        }
                    }

                    
                    if(!$cmdlineOnly) {
                        #finalize progress bar
                        if (			$dialog->{'_ui_dialog'}->can('gauge_set')) {
										$dialog->{'_ui_dialog'}->gauge_set(100);
										#sleep 5;
                        }
                    }

                    #show backup status
                    textbox("Odroid Backup status", $logfile);
                    #backup is finished. Program will now exit.
                }
                else { 	messagebox("Odroid Backup error", "No destination selected for backup. Program will close");	}
            }
            else {		messagebox("Odroid Backup error",  "No partitions selected for backup. Program will close");	}
        }
        
    }
    
    else {				messagebox("Odroid Backup error",       "No disks selected for backup. Program will close");	}
}



# === RESTORE =====================================================================================
if($mainOperation eq 'restore'){
    #select source directory
    my $directory;
    if(defined $options{'directory'}) {
        $directory = $options{'directory'};
    }
    else {
        $directory = $dialog->dselect(title => "Odroid backup - Please select the directory holding your backup", text
                                            => "Please select the directory holding your backup", 'path' => ".");
    }
#    print $directory;																	#TEST
    if($directory){
        #check that there are files we recognize and can restore
        opendir ( DIR, $directory ) || die "Error in opening dir $directory\n";
        my %partitions = ();
        while( (my $filename = readdir(DIR))){
#			print("$filename\n");														#TEST
            if($filename eq 'partition_table.txt'){
                #found MBR
                $partitions{'mbr'}{'start'} = 0;
                $partitions{'mbr'}{'literalType'} = "bin";
                $partitions{'mbr'}{'size'} = 512;
                $partitions{'mbr'}{'sizeHuman'} = 512;
                $partitions{'mbr'}{'label'} = "MBR+EBR";
                $partitions{'mbr'}{'filename'} = "$directory/$filename";
            }
            if($filename eq 'bootloader.bin'){
                #found Bootloader
                $partitions{'bootloader'}{'start'} = 512;
                $partitions{'bootloader'}{'literalType'} = "bin";
                $partitions{'bootloader'}{'size'} = -s "$directory/$filename";
                $partitions{'bootloader'}{'sizeHuman'} = $human->format($partitions{'bootloader'}{'size'});
                $partitions{'bootloader'}{'label'} = "Bootloader";
                $partitions{'bootloader'}{'filename'} = "$directory/$filename";
            }
            if($filename=~/partition_([0-9]+)\.(img|fsa)/){
                my $partition_index = $1;
                my $type = $2;
                #based on the extension we'll extract information about the partition
                if($type eq 'img'){
                    my @output = `$bin{'partclone.info'} -s "$directory/$filename" 2>&1`;
                    print join("\n", @output);
                    foreach my $line(@output){
                        if($line=~/File system:\s+([^\s]+)/){
                            $partitions{$partition_index}{'literalType'} = $1;
                        }
                        if($line=~/Device size:\s+.*= ([0-9]+) Blocks/){
                            #TODO: We assume a block size of 512 bytes
                            my $size = $1;
                            $size *= 512;
                            $partitions{$partition_index}{'size'} = $size;
                            $partitions{$partition_index}{'sizeHuman'} = $human->format($size);
                            $partitions{$partition_index}{'label'} = "Partition $partition_index";
                        }
                    }
                }
                else{
                    #fsa archives
                    my @output = `$bin{'fsarchiver'} archinfo "$directory/$filename" 2>&1`;
                    #this is only designed for one partition per archive, although fsarchiver supports multiple. Not a bug, just as designed :)
                    print join("\n", @output);
                    foreach my $line(@output){
                        if($line=~/Filesystem format:\s+([^\s]+)/){
                            $partitions{$partition_index}{'literalType'} = $1;
                        }
                        if($line=~/Filesystem label:\s+([^\s]+)/){
                            $partitions{$partition_index}{'label'} = "Partition $partition_index ($1)";
                        }
                        if($line=~/Original filesystem size:\s+.*\(([0-9]+) bytes/){
                            $partitions{$partition_index}{'size'} = $1;
                            $partitions{$partition_index}{'sizeHuman'} = $human->format($partitions{$partition_index}{'size'});
                        }
                    }
                }
                $partitions{$partition_index}{'start'} = 0; #we don't need this for restore anyway
                $partitions{$partition_index}{'filename'} = "$directory/$filename";
            }
            if($filename=~/flash_(.*)\.bin/) {
                my $mtddevice = $1;
                #sanity check - the image to be flashed equals the current target size
                my %localDisks = getRemovableDisks();
                if(defined $localDisks{$mtddevice}){
                    my $backupsize = -s "$directory/$filename";
                    if($backupsize == $localDisks{$mtddevice}{'size'}) {
                        $partitions{'flash_' . $mtddevice}{'literalType'} = "bin";
                        $partitions{'flash_' . $mtddevice}{'size'} = $backupsize;
                        $partitions{'flash_' . $mtddevice}{'sizeHuman'} = $human->format($backupsize);
                        $partitions{'flash_' . $mtddevice}{'label'} = "MTD Flash $mtddevice";
                        $partitions{'flash_' . $mtddevice}{'filename'} = "$directory/$filename";
                    }

                }
                else{
                    #silently skip non-matching flash sizes
                }
            }
        }
        closedir(DIR);
        print "Read the following restorable data from the archive directory:\n";
        print Dumper(\%partitions);
        
        #select what to restore
        if(scalar keys %partitions > 0){
            #convert the partitions hash to an array the way checklist expects
            my @displayedPartitions = ();
            foreach my $part (sort keys %partitions){
                push @displayedPartitions, $part;
                my $description = "";
                if(defined $partitions{$part}{label}){
                    $description.="$partitions{$part}{label}, ";
                }
                $description.="$partitions{$part}{sizeHuman}, ";
                
                if(defined $partitions{$part}{literalType}){
                    $description.="$partitions{$part}{literalType}, ";
                }
            
                my @content =  ( $description, 1 );
                push @displayedPartitions, \@content;
            }
            my @selectedPartitions;
            if(defined $options{'partitions'}){
                #partitions should be a comma separated list - convert it to array
                @selectedPartitions = split(',', $options{'partitions'});
                #validate that the names proposed exist in the partition list to be displayed
                foreach my $partition (@selectedPartitions){
                    if(!defined $partitions{$partition}){
                        #the user selection is wrong
                        die "Partition $partition is not a valid selection. Valid options are: ". join(", ", sort keys %partitions);
                    }
                }
            }
            else {
                #create a checkbox selector that allows users to select what they want to backup
                @selectedPartitions = $dialog->checklist(title                            =>
                    "Odroid backup - Please select the partitions you want to restore", text =>
                    "Please select the partitions you want to restore",
                    list                                                                     => \@displayedPartitions);
            }
            #fix an extra "$" being appended to the selected element sometimes by zenity
#			print "Partition list after select box: ". join(",", @selectedPartitions);	#TEST
            for (my $i=0; $i<scalar(@selectedPartitions); $i++){
               if($selectedPartitions[$i]=~/\$$/){
                       $selectedPartitions[$i]=~s/\$$//g;
               							#TEST
            }
            print "Selected to restore the following partitions: ". join(",", @selectedPartitions)."\n";

            
            if(scalar(@selectedPartitions) > 0 && $selectedPartitions[0] ne '0'){
                #convert selectedPartitions to a hash for simpler lookup
                my %selectedPartitionsHash = map { $_ => 1 } @selectedPartitions;
                
                my $partitionCount = scalar(@selectedPartitions);
                my $progressStep = int(100/$partitionCount);
                
                #select destination disk
                #get a list of removable drives (or all drives if so desired)
                my %disks = getRemovableDisks();
                
                #convert the disks hash to an array the way radiolist expects
                my @displayedDisks = ();
                foreach my $disk (sort keys %disks){
                    push @displayedDisks, $disk;
                    my @content =  ( "$disks{$disk}{model}, $disks{$disk}{sizeHuman}, $disks{$disk}{removable}", 0 );
                    push @displayedDisks, \@content;
                }
                
#				print Dumper(\@displayedDisks);											#TEST
                #create a radio dialog for the user to select the desired disk
                my $selectedDisk;
                if(defined $options{'disk'}){
                    #validate if the user option is part of the disks we were going to display
                    my $valid = 0;
                    foreach my $disk (@displayedDisks){
                        if($disk eq $options{'disk'}){
                            $valid = 1;
                            $selectedDisk = $options{'disk'};
                        }
                    }
                    if(!$valid){
                        die "Disk $options{'disk'} is not a valid disk. Valid options are: ".join(" ", sort keys %disks);
                    }
                }
                else {
                    my $selectedDisk = $dialog->radiolist(title =>
                        "Odroid backup - Please select the disk you wish to restore to. Only the selected partitions will be restored.",
                        text                                    =>
                        "Please select the disk you wish to restore to. Only the selected partitions will be restored.",
                        list                                    => \@displayedDisks);
                }
                print "Selected disk to restore to is: $selectedDisk\n";
                
                if($selectedDisk){
                    #Check that the selectedDisk doesn't have mounted partitions anywhere
                    my %mountedPartitions = getMountedPartitions();
                    my $mountError=undef;
                    foreach my $dev (keys %mountedPartitions){
                        if($dev=~/^\/dev\/${selectedDisk}p?([0-9]+)$/){
                            my $number = $1;
                            #found a mounted partition on the target disk. Complain if it was scheduled for restore, or if MBR is to be restored
                            if(defined $selectedPartitionsHash{$number}){
                                $mountError.="$dev is already mounted on $mountedPartitions{$dev} and is scheduled for restore. ";
                            }
                            if(defined $selectedPartitionsHash{'mbr'}){
                                $mountError.="$dev is already mounted on $mountedPartitions{$dev} and MBR is scheduled for restore. ";
                            }
                        }
                    }
                    
                    if(defined $mountError){
                        messagebox("Odroid Backup error", "There are mounted filesystems on the target device. $mountError Restore will abort.");
                        exit;
                    }
                    
                    #perform restore
                    #truncate log
                    `echo "Starting restore process" 																				>  $logfile`;

                    if(!$cmdlineOnly) {
                        #if the backend supports it, display a simple progress bar
                        if ($dialog->{'_ui_dialog'}->can('gauge_start')) {
                            $dialog->{'_ui_dialog'}->gauge_start(title => "Odroid Backup", text =>
                                "Performing restore...", percentage    => 1);
                        }
                    }
                    
                    #restore MBR first
                    if(defined $selectedPartitionsHash{'mbr'}){
                        #we use sfdisk to restore mbr + ebr
                        `echo "\n*** Restoring MBR (Master Boot Record) ***" 														>> $logfile`;
                        `$bin{sfdisk} /dev/$selectedDisk < '$partitions{mbr}{filename}' 											>> $logfile 2>&1 `;
                        $error = $? >> 8;  `echo "Error code: $error" 																>> $logfile 2>&1`;

                        #force the kernel to reread the new partition table
                        `$bin{partprobe} -s /dev/$selectedDisk 																		>> $logfile 2>&1`;
                        
                        sleep 2;

                        if(!$cmdlineOnly) {
                            if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                    }
                    
                    #restore Bootloader second
                    if(defined $selectedPartitionsHash{'bootloader'}){
                        #we use dd to restore bootloader. We skip the partition table even if it's included
                        `echo "\n*** Restoring Bootloader ***" 																		>> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=512 skip=1 seek=1 				>> $logfile 2>&1`;
                        $error = $? >> 8;  `echo "Error code: $error" 																>> $logfile 2>&1`;

                        
                        #BUT, the odroid will likely not boot if the boot code in the MBR is invalid. So we restore it now
                        `echo "*** Restoring Bootstrap code ***" 																	>> $logfile`;
                        `$bin{dd} if='$partitions{bootloader}{filename}' of=/dev/$selectedDisk bs=446 count=1 						>> $logfile 2>&1`;
                        $error = $? >> 8;  `echo "Error code: $error" 																>> $logfile 2>&1`;

                        if(!$cmdlineOnly) {
                            if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                #sleep 5;
                            }
                        }
                    }

                    #restore flash
                    foreach my $part (keys %selectedPartitionsHash){
                        if($part=~/^flash_(.*)/){
                            my $mtd = $1;
                            #this has been checked and should be restoreable on the system (should already exist)
                            `echo "*** Restoring $mtd ***" 																			>> $logfile`;
                            `echo "Erasing $mtd..." 																				>> $logfile`;
                            
                            #first erase it
                            `echo $bin{flash_erase} -q /dev/$mtd 0 0 																>> $logfile 2>&1`;
                            $error = $? >> 8;  `echo "Error code: $error" 															>> $logfile 2>&1`;
                            
                            #next, write it
                            `$bin{dd} if='$partitions{$part}{filename}' of=/dev/$mtd bs=4096 										>> $logfile 2>&1`;
                            $error = $? >> 8;  `echo "Error code: $error"															>> $logfile 2>&1`;

                            if(!$cmdlineOnly) {
                                if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                    $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                    #sleep 5;
                                }
                            }
                        }
                    }

                    #restore remaining partitions
                    foreach my $partition (sort keys %selectedPartitionsHash){
                        if($partition =~/^[0-9]+$/){
                            `echo "*** Restoring Partition $partition ***" 															>> $logfile`;
                            #regular partition. Based on the filesystem we dump it either with fsarchiver or partclone
                            my $partitionNumber = $partition;
                            
                            #note that we need to restore to a partition, not a disk. So we'll need to construct/detect what the corresponding partition numbers are
                            #this program only supports a 1:1 mapping with what's in the archive (nothing fancy). The mapping may be incomplete and flawed for some
                            #use cases - patches welcome
                            
                            my $partitionDev = "";
                            if($selectedDisk =~/mmcblk|loop/){
                                #these ones have a "p" appended between disk and partition (e.g. mmcblk0p1)
                                $partitionDev = $selectedDisk."p".$partitionNumber;
                            }
                            else{
                                #partition goes immediately after the disk name (e.g. sdd1)
                                $partitionDev = $selectedDisk.$partitionNumber;
                            }
                            
                            if($partitions{$partition}{literalType} eq 'vfat' || $partitions{$partition}{literalType} eq 'btrfs' || $partitions{$partition}{literalType} eq 'BTRFS' || $partitions{$partition}{literalType} eq 'FAT16' || $partitions{$partition}{literalType} eq 'FAT32'){
                                #we use partclone
                                `$bin{'partclone.restore'} -s '$partitions{$partitionNumber}{filename}' -o '/dev/$partitionDev' 	>> $logfile 2>&1`;
                                $error = $? >> 8;
                                `echo "Error code: $error" 																			>> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            elsif($partitions{$partition}{literalType} =~/ext[234]/i){
                                #we use fsarchiver
                                `$bin{'fsarchiver'} restfs '$partitions{$partitionNumber}{filename}' id=0,dest=/dev/$partitionDev 	>> $logfile 2>&1`;
                                $error = $? >> 8;  `echo "Error code: $error" 														>> $logfile 2>&1`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                            elsif($partitions{$partition}{type} eq '5'){
                                #extended partition - nothing to do, it will be restored via sfdisk automatically
                            }
                            else{
                                #not supported filesystem type!
                                messagebox("Odroid Backup error", "The partition $partition has a non-supported filesystem. Restore will skip it");
                                `echo "*** Skipping partition $partition because it has an unsupported type ($partitions{$partition}{literalType}) ***" >> $logfile`;

                                if(!$cmdlineOnly) {
                                    if ($dialog->{'_ui_dialog'}->can('gauge_inc')) {
                                        $dialog->{'_ui_dialog'}->gauge_inc($progressStep);
                                        #sleep 5;
                                    }
                                }
                            }
                        }
                    }
                }

                if(!$cmdlineOnly) {
                    #finalize progress bar
                    if ($dialog->{'_ui_dialog'}->can('gauge_set')) {
                        $dialog->{'_ui_dialog'}->gauge_set(100);
                        #sleep 5;
                    }
                }
                
                #show backup status
                textbox("Odroid Backup status", $logfile);
                #restore is finished. Program will now exit.
            }
            else{
                messagebox("Odroid Backup error", "No partitions selected for restore. Program will close");
            }
        }
        else{
            #we found nothing useful in the backup dir
            messagebox("Odroid Backup error", "No backups found in $directory. Program will close");
        }
    }
}


# =================================================================================================
# === SUBS ========================================================================================
# =================================================================================================

# ---------------------------------------------------------------------------
sub getPartitions{
	#get a list of partitions of a specified disk
    my $disk 		= shift;
    
    my $jsonData 	= `$bin{sfdisk} -l -J /dev/$disk`;									#-l, --list [device...] List the partitions of all or the specified devices.
																						#-J, --json device		Dump the partitions of a device in JSON format. 
															
=begin  Here is an example of what this looks like when converted to JSON

	root@Love2d:/proc# sfdisk -l /dev/sda
	
	Disk /dev/sda: 465.8 GiB, 500107862016 bytes, 976773168 sectors
	Units: sectors of 1 * 512 = 512 bytes
	Sector size (logical/physical): 512 bytes / 512 bytes
	I/O size (minimum/optimal): 512 bytes / 512 bytes
	Disklabel type: dos
	Disk identifier: 0x39e5896d

	Device     Boot     Start       End   Sectors   Size Id Type
	/dev/sda1  *         2048    409599    407552   199M  7 HPFS/NTFS/exFAT
	/dev/sda2          409600 344375295 343965696   164G  7 HPFS/NTFS/exFAT
	/dev/sda3       344375296 407289855  62914560    30G  7 HPFS/NTFS/exFAT
	/dev/sda4       407289856 976773167 569483312 271.6G  5 Extended
	/dev/sda5       407291904 424069119  16777216     8G 82 Linux swap / Solaris
	/dev/sda6  *    424071168 549900287 125829120    60G 83 Linux
	/dev/sda7       549902336 554096639   4194304     2G 83 Linux
	/dev/sda8       554098688 596041727  41943040    20G 83 Linux
	/dev/sda9       596043776 753330175 157286400    75G  7 HPFS/NTFS/exFAT
	/dev/sda10      753332224 976773167 223440944 106.6G 83 Linux
	
	
	root@Love2d:/proc# sfdisk -l -J /dev/sda
	
	{
	"partitiontable": {
		"label": "dos",
		"id": "0x39e5896d",
		"device": "/dev/sda",
		"unit": "sectors",
		"partitions": [
			{"node": "/dev/sda1", "start": 2048, "size": 407552, "type": "7", "bootable": true},
			{"node": "/dev/sda2", "start": 409600, "size": 343965696, "type": "7"},
			{"node": "/dev/sda3", "start": 344375296, "size": 62914560, "type": "7"},
			{"node": "/dev/sda4", "start": 407289856, "size": 569483312, "type": "5"},
			{"node": "/dev/sda5", "start": 407291904, "size": 16777216, "type": "82"},
			{"node": "/dev/sda6", "start": 424071168, "size": 125829120, "type": "83", "bootable": true},
			{"node": "/dev/sda7", "start": 549902336, "size": 4194304, "type": "83"},
			{"node": "/dev/sda8", "start": 554098688, "size": 41943040, "type": "83"},
			{"node": "/dev/sda9", "start": 596043776, "size": 157286400, "type": "7"},
			{"node": "/dev/sda10", "start": 753332224, "size": 223440944, "type": "83"}
		]
	}
}

=cut
															
															
    print Dumper($jsonData);															#Strinify to output
    
    my %partitions = ();																#Hash to accumulate partitions to
    
    
    my %mounted = getMountedPartitions();
    
    if($jsonData){
        my $json = JSON->new->allow_nonref;												#??		JSON - JSON (JavaScript Object Notation) encoder/decoder
																						#JSON->new		Creates a new JSON::XS-compatible backend object that can be used to de/encode JSON strings
															
        my $sfdisk = $json->decode($jsonData);											#expects a JSON text and tries to parse it, returning the resulting simple scalar or (object) reference.
        print Dumper($sfdisk);															#Strinify to output
        
        
        if(defined $sfdisk->{partitiontable}{partitions}){
        
            #add the MBR + EBR entry
														$partitions{'mbr'			}{'start'		} =   0;
														$partitions{'mbr'			}{'type'		} =   0;
														$partitions{'mbr'			}{'size'		} = 512;
														$partitions{'mbr'			}{'sizeHuman'	} = 512;
														$partitions{'mbr'			}{'label'		} = "MBR+EBR";
            
            #we need to find out where the first partition starts
            my $minOffset = 999_999_999_999;
            
            #list partitions from sfdisk + get their type
            foreach my $part (@{$sfdisk->{partitiontable}{partitions}}){			# $sfdisk is an object (I think)??  It has a nested hash.  This somehow gets an array I think.
            
														$partitions{$part->{node}	}{'start'		} = $part->{start};
														$partitions{$part->{node}	}{'type'		} = $part->{type};
                
                my $size = getDiskSize($part->{node});
														$partitions{$part->{node}	}{'size'		} = 				 $size ;
														$partitions{$part->{node}	}{'sizeHuman'	} = $human->format($size);
                
                #also get UUID and maybe label from blkid
                my $output = `$bin{blkid} $part->{node}`;
                if($output=~/\s+UUID=\"([^\"]+)\"/){	$partitions{$part->{node}	}{'uuid'		} = $1; }
                if($output=~/\s+LABEL=\"([^\"]+)\"/){	$partitions{$part->{node}	}{'label'		} = $1;	}
                if($output=~/\s+TYPE=\"([^\"]+)\"/){	$partitions{$part->{node}	}{'literalType'	} = $1;	}
                
                #find out if the filesystem is mounted from /proc/mounts
                if(defined $mounted{$part->{node}}){	$partitions{$part->{node}	}{'mounted'		} = $mounted{$part->{node}};	}
                
                $minOffset = $part->{start} if($minOffset > $part->{start});
            }
            
            #add the bootloader entry - starting from MBR up to the first partition start offset
            #We assume a sector size of 512 bytes - possible source of bugs !!!
														$partitions{'bootloader'	}{'start'		} = 1;
														$partitions{'bootloader'	}{'end'			} = $minOffset;
														$partitions{'bootloader'	}{'type'		} = 0;
														$partitions{'bootloader'	}{'size'		} = ($minOffset - 1)*512;
														$partitions{'bootloader'	}{'sizeHuman'	} = $human->format($partitions{'bootloader'}{'size'});
														$partitions{'bootloader'	}{'label'		} = "Bootloader";
            
        }
        else{											$partitions{"error"			}{'label'		} = "Error - did not find any partitions on device!";	}
    }
    else{												$partitions{"error"			}{'label'		} = "Error running sfdisk. No medium?";					}
    
    return %partitions;
}


# ---------------------------------------------------------------------------
sub getMountedPartitions{
    open MOUNTS, "/proc/mounts" or die "Unable to open /proc/mounts. $!";
    my %filesystems = ();
    while(<MOUNTS>){
        #/dev/sdb2 / ext4 rw,relatime,errors=remount-ro,data=ordered 0 0
        if(/^(\/dev\/[^\s]+)\s+([^\s]+)\s+/){ $filesystems{$1}=$2; }					#e.g. /dev/sda2 => /home/howard/Shared
    }
    close MOUNTS;
    return %filesystems;
}


# ---------------------------------------------------------------------------
sub getRemovableDisks{
    my %disks=();		#Hash to save disks found to ???
    
    opendir(my $dh, "/sys/block/") || die "Can't opendir /sys/block: $!";
    while (readdir $dh) {
    
        my $block = $_;																	#Get next thing in this directory
        next if ($block eq '.' || $block eq '..');										#Skip . and ..
        
#		print "/sys/block/$block\n";													#TEST

        my @info = `$bin{udevadm} info -a --path=/sys/block/$block 2>/dev/null`;		#e.g. sudo udevadm info -a --path=/sys/block/sda

        my $model = "";
        my $removable = 0;
		foreach my $line (@info){
		
			#Get device model
           if($line=~/ATTRS\{model\}==\"(.*)\"/){										#Search for attribute for 'model', e.g. =="Samsung SSD 850 ".  Return what is inside ( and ), i.e. inside double quotes in $1 below:
                $model = $1;
                $model=~s/^\s+|\s+$//g;													# \s matches whitespace; so this removes exterior whitespace
            }
            
			#Get device's removable flag (if not found defaults to 0)
			if($line=~/ATTR\{removable\}==\"(.*)\"/){									#Search for attribute for 'removable' (1 or 0)
                $removable = $1;
                $removable = ($removable == 1)?"removable":"non-removable";				#Change $removable into a string
            }
        }
        
        if(defined $options{'allDisks'} || $removable eq 'removable'){
				my $size = getDiskSize($block);
				$disks{$block}{sizeHuman} 		= $human->format($size);				# A hash of a hash!
				$disks{$block}{size} 			= 				 $size ;
				$disks{$block}{model} 			= $model;
				$disks{$block}{removable} 		= $removable;
        }
#        print "$block\t$model\t$removable\n";											#TEST
    }
    
    # Also look for NAND flash and show it as a disk
    if(open NAND, "/proc/mtd"){
        while(<NAND>){
            if(/^([^\s]+):\s+([0-9a-f]+)\s+([0-9a-f]+)\s+\"([^\"]+)\"/){
                my $mtddevice 	= $1;
                my $hexsize 	= $2;
                my $erase 		= $3;
                my $name 		= $4;
                
                $disks{$mtddevice}{sizeHuman} 	= $human->format(hex($hexsize));
                $disks{$mtddevice}{size} 		= 				 hex($hexsize) ;
                $disks{$mtddevice}{model} 		= "MTD Flash $name";
                $disks{$mtddevice}{removable} 	= "non-removable";
            }
        }
    }

    return %disks;
    
}


# ---------------------------------------------------------------------------
sub getDiskSize{
    my $disk 	= shift;
       $disk = "/dev/$disk" if($disk !~ /^\/dev\//);									#If $disk does not have /dev/ prefix, then add it
#    print Dumper(\$disk);

    my $size = `$bin{blockdev} --getsize64 $disk 2>/dev/null`;							#???
    $size=~s/\r|\n//g;
    return $size;
}


# ---------------------------------------------------------------------------
sub checkRootUser{
    if($< != 0){		# $<  = The real user ID ( uid) of this process.
        messagebox("Odroid Backup error", "You need to run this program as root");
        exit 2;
    }
}


# ---------------------------------------------------------------------------
#issue a warning to let the users know that they might clobber their system if they are not careful
sub firstTimeWarning{
    my $homedir = (getpwuid $>)[7];
    if(! -f $homedir."/.odroid-backup"){
        #running the first time
        messagebox("Odroid Backup warning", "WARNING: This script attempts to backup and restore eMMCs and SD cards for Odroid systems. It should work with other systems as well, but it was not tested. Since restore can be a dangerous activity take the time to understand what's going on and make sure you're not destroying valuable data. It is wise to test a backup after it was made (image it to a different card and try to boot the system) in order to rule out backup errors. When backup or restore completes you will be presented with a log of what happened. It is wise to review the log, since not all errors are caught by this script (actually none is treated). I am not responsible for corrupted backups, impossible to restore backups, premature baldness or World War 3. This is your only warning! Good luck!");
        
        #create a file in the user's homedir so that we remember he or she's been warned
        open  FILE, ">$homedir/.odroid-backup" or die "Unable to write $homedir/.odroid-backup";
        close FILE;
    }
}



# ---------------------------------------------------------------------------
sub messagebox{
    my $title 	= shift;
    my $text 	= shift;

    if($cmdlineOnly){ print "$title: $text\n";								} else { $dialog->msgbox(title => $title, text => $text); }
}

# ---------------------------------------------------------------------------
sub textbox{
    my $title 	= shift;
    my $file 	= shift;
    
    if($cmdlineOnly){ print "$title:\n"; print `cat "$file"`; print "\n";	} else { $dialog->textbox(title => $title, path => $file); }
}



# ---------------------------------------------------------------------------
sub checkDependencies{
    
	# --- check for sfdisk, partclone, fsarchiver and perl modules
 	my  $message 		= "";															#Accumulated message string below
 	
    my %cpanToInstall 	= ();															#Hash of which cpan modules to install
    my  %pkgToInstall 	= ();															#Hash of which packages 	to install

    
    if(!$cmdlineOnly) {
		my  $rc = 0;																	#Results Code -- of `require UI::Dialog` check; defaults to false (if command line mode)
		$rc = eval { require UI::Dialog; 1; }; 											#Try to load UI::Dialog.
		
        if ($rc) {
            # UI::Dialog loaded and imported successfully
            # initialize it and display errors via UI
            my  							 @ui = ('zenity', 'dialog', 'ascii');		#defaults to all
            if (defined $options{'text' }) { @ui = (		  'dialog', 'ascii'); }		#force rendering only with dialog
            if (defined $options{'ASCII'}) { @ui = (					'ascii'); }		#force rendering only with ascii

            $dialog = new UI::Dialog (backtitle => "Odroid Backup", debug => 0, width => 400, height => 400, order => \@ui, literal => 1);

        }
        else {						$message .= "UI::Dialog missing...\n";				#If UI::Dialog is missing, then try to install underlying dialog components that we need ???
																						$cpanToInstall{'UI::Dialog'	} = 1;
																						 $pkgToInstall{'zenity'						} = 1;					#Adds 'zenity' => 1 to hash
																						 $pkgToInstall{'dialog'						} = 1;					#Adds 'dialog' => 1 to hash
        }
    }
    
    
    # --- check if other needed perl modules are available
    my $readable 	= eval{	require Number::Bytes::Human; 	1; };
    if(!$readable){					$message .= "Number::Bytes::Human missing...\n";	 $pkgToInstall{'libnumber-bytes-human-perl'	} = 1; 	}	#This is the old way?  ???
    
    my $json 		= eval{ require JSON;					1; };
    if(!$json){						$message .= "JSON missing...\n";					 $pkgToInstall{'libjson-perl'				} = 1;	}
    
    
    # --- check if system binaries dependencies are available
    foreach my $program (sort keys %dependencies){
           $bin{$program} = `which $program`;
           $bin{$program} =~s/\s+|\r|\n//g;
        if($bin{$program} eq ''){	$message .= "$program missing...\n";				 $pkgToInstall{$dependencies{$program}		} = 1;
        }
    }

    
    # --- Append message to install any missing:  packages
    if(scalar keys  %pkgToInstall > 0){
        my $packages = join(" ", keys  %pkgToInstall);
									$message .= "To install missing dependencies run\n  sudo apt-get install $packages\n";
    }

    # --- Append message to install any missing:  perl modules
    if(scalar keys %cpanToInstall) {$message .= "To install missing perl modules run\n";
        foreach my $module (sort keys %cpanToInstall) {
									$message .= "  sudo perl -MCPAN -e 'install $module'\n";
        }
    }

    
    # --- Finally, complain with a full list of any missing required packages or perl modules
    if($message ne ''){				$message = "Odroid Backup needs the following packages to function:\n\n$message";

        messagebox("Odroid Backup error", $message);
        exit 1;
    }
}
