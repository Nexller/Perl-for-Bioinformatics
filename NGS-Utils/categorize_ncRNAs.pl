#!/usr/bin/env perl

use strict;
use Carp;
use Getopt::Long qw(:config pass_through);
use IO::Routine;
use Set::IntervalTree;
use Parallel::ForkManager;
use Fcntl qw / :flock SEEK_END /;

my ($LASTCHANGEDBY) = q$LastChangedBy: konganti $ =~ m/.+?\:(.+)/;
my ($LASTCHANGEDDATE) = q$LastChangedDate: 2018-02-20 11:47:27 -0500 (Tue, 20 Feb 2018)  $ =~ m/.+?\:(.+)/;
my ($VERSION) = q$LastChangedRevision: 1044 $ =~ m/.+?(\d+)/;
my $AUTHORFULLNAME = 'Kranti Konganti';

my ($help, $quiet, $cuffcmp, $genePred, $out, $sample_names,
    $fpkm_cutoff, $cov_cutoff, $refGenePred, $length, $categorize,
    $min_exons, $overlap, $novel, $extract_pat, $no_tmp,
    $antisense_only, $disp_anti_option, $gtf_bin, $num_cpu,
    $linc_rna_prox, $ncRNA_max_length, $extract_pat_user,
    $ignore_genePred_err, $full_read_supp, $rescue, $gtf_formatted,
    $known_ncRNAs);

my ($p_file_names_gtf, $p_file_names_txt) = [];
my $ncRNA_class = {};
my $full_read_supp_def = 'yes|no';

my $is_valid_option = GetOptions('help|?'              => \$help,
				 'quiet'               => \$quiet,
				 'cuffcmp=s'           => \$cuffcmp,
				 'annotation=s'        => \$refGenePred,
				 'out=s'               => \$out,
				 'sample-names=s'      => \$sample_names,
				 'fpkm-cutoff=f'       => \$fpkm_cutoff,
				 'cov-cutoff=f'        => \$cov_cutoff, 
				 'genePred'            => \$genePred,
				 'categorize'          => \$categorize,
				 'length=i'            => \$length,
				 'max-length=i'        => \$ncRNA_max_length,
				 'min-exons=i'         => \$min_exons,
				 'known-ncRNAs'        => \$known_ncRNAs,
				 'overlap=f'           => \$overlap,
				 'include-novel'       => \$novel,
				 'clean-tmp'           => \$no_tmp,
				 'bin-gtfToGenePred=s' => \$gtf_bin,
				 'antisense-only'      => \$antisense_only,
				 'cpu=i'               => \$num_cpu,
				 'linc-rna-prox=i'     => \$linc_rna_prox,
				 'full-read-support'   => \$full_read_supp,
				 'ignore-genePred-err' => \$ignore_genePred_err,
				 'extract-pattern=s'   => \$extract_pat_user,
				 'rescue-categories'   => \$rescue);

my $io = IO::Routine->new($help, $quiet);
my $s_time = $io->start_timer;

$io->verify_options([$is_valid_option, $sample_names, 
		     $refGenePred, $out, $cuffcmp]);

$io->this_script_info($io->file_basename($0),
		      $VERSION,
		      $AUTHORFULLNAME,
		      $LASTCHANGEDBY,
		      $LASTCHANGEDDATE, '', 
		      $quiet);

$io->c_time('Analysis started...');
$io->c_time('Verifying options...');

# Clean up warnings
remove_warnings('Removing warnings from previous run, if any...');

# Define Defaults
$fpkm_cutoff = 0.0 if (!defined $fpkm_cutoff || $fpkm_cutoff eq '');
$cov_cutoff = 0.0 if (!defined $cov_cutoff || $cov_cutoff eq '');
$length = 200 if (!defined $length || $length eq '');
$overlap = 0 if (!defined $overlap || $overlap eq '');
$min_exons = 1 if (!defined $min_exons || $min_exons eq '');
$full_read_supp_def = 'yes' if (defined $full_read_supp);

$io->c_time('Validating output path...');
my $output = $io->validate_create_path($out, 'create', 
				       'Output directory');

$io->c_time('Checking for required GNU core utils...');
$io->check_sys_level_cmds(['grep', 'sed', 'wc'], 
			  ['2.6.3', '4.2.1', '0']);

$io->c_time('Checking for annotation file in Gene Prediction format...');
$io->verify_files([$refGenePred], ['Gene Prediction']);
my $refGenePred_fh = $io->open_file('<', $refGenePred);

$io->c_time('Checking for Cuffcompare tracking and Cufflinks assembled transcript files...');
my $cuffcmp_fh = $io->open_file('<', $cuffcmp);

$io->error('Cufflinks assembled transcript files not provided.')
    if ($#ARGV < 0);

$io->c_time('Tainting sample names...');
$sample_names = $io->strip_leading_and_trailing_spaces($sample_names);
$sample_names =~ s/\s+/\_/g;
$sample_names =~ s/\,$//;
my @lables = split/\,/, $sample_names;

$io->error('Number of Sample Names [ ' . scalar(@lables) . " ] is not equal to Number of transcripts' files [ " . scalar(@ARGV) .' ] provided.')
    if ($#lables != $#ARGV);

# Check validity of attribute column of GTF file
$io->c_time('Checking for the validity of attribute column [ 9th column ] in supplied transcript assembly [ GTF ] file(s)...');

# Check point names
my $get_putative_ncRNAs_chkpt = $output . '.get_putative_ncRNAs.OK';
my $get_genePred_chkpt = $output . '.get_genePred.OK';
my $cat_class_zero = $output . '.cat.extractPat.zero';

for (0 .. $#ARGV) {
    $io->verify_files([$ARGV[$_]],
                      ["Cufflinks assembled transcript"]);
    $ARGV[$_] = check_gtf_attributes($ARGV[$_], $lables[$_]);
    if ($gtf_formatted) {
	push @{$p_file_names_gtf}, $output . $io->file_basename($ARGV[$_]) . '.putative_lncRNAs.gtf';
	push @{$p_file_names_txt}, $output . $io->file_basename($ARGV[$_]) . '.putative_lncRNAs.txt';

    }
    else {
	push @{$p_file_names_gtf}, $output . $io->file_basename($ARGV[$_]) . '.' . $lables[$_] . '.putative_lncRNAs.gtf';
	push @{$p_file_names_txt}, $output . $io->file_basename($ARGV[$_]) . '.' . $lables[$_] . '.putative_lncRNAs.txt';
    }
    unlink $p_file_names_gtf->[$_] if (-e $p_file_names_gtf->[$_] && !defined($genePred) && !defined($categorize));
}

$disp_anti_option = 'True' if (defined($antisense_only));
$disp_anti_option = 'False' if (!defined($antisense_only));

if (defined($categorize) || (-e $get_genePred_chkpt && -e $get_putative_ncRNAs_chkpt)) {    
    $io->execute_system_command(0,
				"Using options:\n--------------\n" .
				"Minimum transcript length              : $length\n" .
				"Minimum exon overlap percentage        : $overlap\n" .
				"Minimum number of exons per transcript : $min_exons\n" .
				"Extract only Antisense exon overlaps   : $disp_anti_option");
    class_ncRNAs();
}
elsif (defined($genePred) || -e $get_putative_ncRNAs_chkpt) {
    $io->execute_system_command(0,
                                "Using options:\n--------------\n" .
                                "Minimum transcript length              : $length\n" .
                                "Minimum exon overlap percentage        : $overlap\n" .
				"Minimum number of exons per transcript : $min_exons\n" . 
				"Extract only Antisense exon overlaps   : $disp_anti_option");
    get_genePred();
    class_ncRNAs();
}
else {
    $io->execute_system_command(0,
				"Using options:\n--------------\n" .
				"FPKM cutoff                            : $fpkm_cutoff\n" .
				"Coverage cutoff                        : $cov_cutoff\n".
				"Minimum transcript length              : $length\n" .
				"Minimum exon overlap percentage        : $overlap\n" .
				"Minimum number of exons per transcript : $min_exons\n" . 
				"Extract only Antisense exon overlaps   : $disp_anti_option");
    get_putative_ncRNAs();
    get_genePred();
    class_ncRNAs();
}

if (defined($no_tmp)) {
    $io->c_time('Removing intermediate files...');
    for (0 .. $#ARGV) {
	unlink $p_file_names_gtf->[$_];
	unlink $p_file_names_txt->[$_];
    }
}

# Clean up warnings
remove_warnings('Removing warnings for this run...');

$io->c_time('Known ncRNAs are stored in files ending with suffix ".putative.class.lncRNAs.gtf"') if (defined $known_ncRNAs);
$io->c_time('categorize_ncRNAs finished!');
$io->end_timer($s_time);
exit;



############################# Functions ###############################

# Get putative list of ncRNAs from Cuffcompare tracking file corresponding
# to cufflinks assembled transcript fragments.
sub get_putative_ncRNAs {
    $io->c_time('Getting putative list of lncRNAs in GTF format...');
    my $cpu = '';

    if (defined $novel) {
	$extract_pat = 'j|i|o|u|x';
    }
    else {
	$extract_pat = 'i|o|u|x';
    }

    if (defined $extract_pat_user && $extract_pat_user ne '') {
	$extract_pat = $extract_pat_user;
	$io->c_time('Using user defined pattern to extract transcripts belonging to the provided class codes [ ' . $extract_pat . ' ]...');
    }

    if (defined $num_cpu) {
        $cpu = Parallel::ForkManager->new($num_cpu);
        $cpu->set_max_procs($num_cpu);
    }
    
    while (my $line = <$cuffcmp_fh>) {
	my $parallel_pid = $cpu->start and next if (defined $num_cpu);
	
	chomp $line;
	$line = $io->strip_leading_and_trailing_spaces($line);
	my ($t_id, $loc_id, $loc_name, $class_code, @cols) = split/\t/, $line;

	$io->error('Number of sample columns in Cuffcompare tracking file do not match number of assembled transcript files supplied')
	    if ($#cols != $#ARGV);

	if ($class_code =~ m/$extract_pat/i) {
	    for (0 .. $#cols) {
		my ($q_loc_id, $q_t_id, $discard) = split/\|/, $cols[$_];
		next if (!$q_t_id || $q_t_id eq '');
		$q_t_id =~ s/\./\\./g;
		my $t_lines = $io->execute_get_sys_cmd_output('grep -P \'transcript_id\s+\"' . $q_t_id . '\"\' ' . $ARGV[$_], 0);
		
		if (defined $cov_cutoff && $cov_cutoff > 0 && $t_lines !~ m/.*?cov.+?\"(.+?)\".*/i && !-e $output . '.cat_cov_cutoff.war') {
		    my $local_fh = $io->open_file('>', $output . '.cat_cov_cutoff.war');
		    $io->warning("Coverage information not present in the input transcript assemblies.\n" .
				 'Transcripts will not be filtered based on coverage cutoff.');
		    close $local_fh;
		}
		if (defined $fpkm_cutoff && $fpkm_cutoff > 0 && $t_lines !~ m/.*?[FR]PKM.+?\"(.+?)\".*/i && !-e $output . '.cat_fpkm_cutoff.war') {
		    my $local_fh = $io->open_file('>', $output . '.cat_fpkm_cutoff.war');
		    $io->warning("FPKM / RPKM information not present in the input transcript assemblies.\n" .
				 'Transcripts will not be filtered based on FPKM / RPKM cutoff.');
		    close $local_fh;
		}
		if (defined $full_read_supp && $t_lines !~ m/.*?full\_read\_support.+?\"(yes|no)\".*/i && !-e $output . '.cat_full_read_supp.war') {
		    my $local_fh = $io->open_file('>', $output . '.cat_full_read_supp.war');
		    $io->warning("Full read support information not present in the input transcript assemblies.\n" .
				 'Transcripts will not be filtered based on full read support information.');
		    close $local_fh;
		}

		my $p_lncRNAs = '';
		if ($t_lines =~ m/.+?[FR]PKM.+?\"(.+?)\".+?cov.+?\"(.+?)\".+?full\_read\_support.+?\"(yes|no)\".*/i) {
		    $p_lncRNAs = $io->execute_get_sys_cmd_output('grep -P \'transcript_id\s+\"' . $q_t_id . '\"\' ' . $ARGV[$_] . " | sed -e \'s\/\$\/ class_code \"$class_code\"\;\/'")
			if ($1 >= $fpkm_cutoff && $2 >= $cov_cutoff && $3 =~ m/$full_read_supp_def/i);
		}
		elsif ($t_lines =~ m/.+?[FR]PKM.+?\"(.+?)\".+?cov.+?\"(.+?)\".*/i) {
		    $p_lncRNAs = $io->execute_get_sys_cmd_output('grep -P \'transcript_id\s+\"' . $q_t_id . '\"\' ' . $ARGV[$_] . " | sed -e \'s\/\$\/ class_code \"$class_code\"\;\/'")
			if ($1 >= $fpkm_cutoff && $2 >= $cov_cutoff);
		}
		elsif ($t_lines =~ m/.+?[FR]PKM.+?\"(.+?)\".*/i) {
		    $p_lncRNAs = $io->execute_get_sys_cmd_output('grep -P \'transcript_id\s+\"' . $q_t_id . '\"\' ' . $ARGV[$_] . " | sed -e \'s\/\$\/ class_code \"$class_code\"\;\/'")
			if ($1 >= $fpkm_cutoff);
		}
		else {
		    $p_lncRNAs = $io->execute_get_sys_cmd_output('grep -P \'transcript_id\s+\"' . $q_t_id . '\"\' ' . $ARGV[$_] . " | sed -e \'s\/\$\/ class_code \"$class_code\"\;\/'");
		}

		my $p_file_names_gtf_fh = $io->open_file('>>', $p_file_names_gtf->[$_]);

		if (defined $num_cpu) {
		    flock($p_file_names_gtf_fh, LOCK_EX) or $io->error('Parallel PID: [ ' . $$ . ' ]: File lock error!');
		    seek($p_file_names_gtf_fh, 0, SEEK_END) or $io->error('Cannot seek to end of file after lock: File lock error!');
		}
			
		print $p_file_names_gtf_fh $p_lncRNAs or $io->error('Cannot write to [ ' . $p_file_names_gtf->[$_] . ' ]...');
		close $p_file_names_gtf_fh;
	    }
	}
	$cpu->finish if (defined $num_cpu);
    }
    $cpu->wait_all_children if (defined $num_cpu);
    $io->execute_system_command("touch $get_putative_ncRNAs_chkpt");
    
    check_for_zero_class();

    return;
}

# Convert GTF to gene prediction format.
sub get_genePred {
    my $cpu = '';
    $io->c_time('Converting putative ncRNAs list to Gene Prediction format using gtfToGenePred tool...');
    
    check_for_zero_class();

    my $exe_gtfToGenePred = 'gtfToGenePred';
    $exe_gtfToGenePred = $gtf_bin if (defined($gtf_bin) && $gtf_bin ne '');

    my $check_for_gtfToGenePred = $io->execute_get_sys_cmd_output($exe_gtfToGenePred, 0);
    
    $io->error('Cannot find gtfToGenePred tool in your path') 
	if ($check_for_gtfToGenePred !~ m/.*?gtfToGenePred.*?convert a GTF file to a genePred/i);

    if (defined $num_cpu) {
        $cpu = Parallel::ForkManager->new($num_cpu);
	$cpu->set_max_procs($num_cpu);
    }
    
    for (0 .. $#$p_file_names_gtf) {
	$cpu->start and next if (defined $num_cpu);
	$io->verify_files([$p_file_names_gtf->[$_]], ['GTF']);
	$io->execute_system_command("$exe_gtfToGenePred -genePredExt -geneNameAsName2 $p_file_names_gtf->[$_] $p_file_names_txt->[$_] 2> /dev/null",
	    "Command call:\n-------------\n$exe_gtfToGenePred -genePredExt -geneNameAsName2 $p_file_names_gtf->[$_] $p_file_names_txt->[$_] 2> /dev/null");
	$cpu->finish if (defined $num_cpu);
    }
    $cpu->wait_all_children if (defined $num_cpu);
    $io->execute_system_command("touch $get_genePred_chkpt");
    return;
}

# Categorize ncRNAs
sub class_ncRNAs {
    my $refAnnot = store_coords($refGenePred);
    my $cpu = my $info_sync_word = '';

    check_for_zero_class();

    if (defined $num_cpu) {
	$cpu = Parallel::ForkManager->new($num_cpu);
	$cpu->set_max_procs($num_cpu);
    }

    for (0 .. $#ARGV) {

	$cpu->start and next if (defined $num_cpu);

        my $p_gtf = $p_file_names_gtf->[$_];
        my $p_ncRNAs = store_coords($p_file_names_txt->[$_]);
	my $c_ncRNAs = my $u_ncRNAs = '';
	
	if ($gtf_formatted) {
	    $c_ncRNAs = $output . $io->file_basename($ARGV[$_]) . '.putative.class.lncRNAs.gtf';
	    $u_ncRNAs = $output . $io->file_basename($ARGV[$_]) . '.putative.noClass.lncRNAs.gtf';	    
	}
	else {
	    $c_ncRNAs = $output . $io->file_basename($ARGV[$_]) . '.' . $lables[$_] . '.putative.class.lncRNAs.gtf';
	    $u_ncRNAs = $output . $io->file_basename($ARGV[$_]) . '.' . $lables[$_] . '.putative.noClass.lncRNAs.gtf';
	}
	
	unlink $c_ncRNAs if (-e $c_ncRNAs);
	unlink $u_ncRNAs if (-e $u_ncRNAs);

	chomp (my $total_nc_trs_before_cat = $io->execute_get_sys_cmd_output("grep -P '\ttranscript\t' $ARGV[$_] | wc -l"));
	$total_nc_trs_before_cat = 'NA' if (!$total_nc_trs_before_cat);
	
	my ($num_ex_ov, $num_incs, $num_concs, $num_poncs, $num_lincs, $noclass, $num_noSense,
	    $discard) = 0;

	if (!defined $rescue) {
	    $info_sync_word = ' and syncing ';
	}
	else {
	    $info_sync_word = ' ';
	}

	$io->c_time('Categorizing' . $info_sync_word . 'lncRNAs (Exonic overlaps) [ ' . $io->file_basename($p_file_names_gtf->[$_], 'suffix') . ' ]...');
	($num_ex_ov, $num_noSense) = calc_overlaps('exonic', $p_gtf, $p_ncRNAs, $c_ncRNAs, $refAnnot, $u_ncRNAs);

	if (!defined $known_ncRNAs) {
	    $io->c_time('Categorizing' . $info_sync_word . 'lncRNAs (Intronic overlaps - Incs) [ ' . $io->file_basename($p_file_names_gtf->[$_], 'suffix') . ' ]...');
	    ($num_incs, $discard) = calc_overlaps('Inc', $p_gtf, $p_ncRNAs, $c_ncRNAs, $refAnnot);
	}

	if (!defined $known_ncRNAs) {
	    $io->c_time('Categorizing' . $info_sync_word . 'lncRNAs (Intronic overlaps - Concs) [ ' . $io->file_basename($p_file_names_gtf->[$_], 'suffix') . ' ]...');
	    ($num_concs, $discard) = calc_overlaps('Conc', $p_gtf, $p_ncRNAs, $c_ncRNAs, $refAnnot);
	}

	if (!defined $known_ncRNAs) {
	    $io->c_time('Categorizing' . $info_sync_word . 'lncRNAs (Intronic overlaps - Poncs) [ ' . $io->file_basename($p_file_names_gtf->[$_], 'suffix') . ' ]...');
	    ($num_poncs, $discard) = calc_overlaps('Ponc', $p_gtf, $p_ncRNAs, $c_ncRNAs, $refAnnot);
	}

	if (!defined $known_ncRNAs) {
	    $io->c_time('Categorizing' . $info_sync_word . 'lncRNAs (lincRNA) [ ' . $io->file_basename($p_file_names_gtf->[$_], 'suffix') . ' ]...');
	    ($num_lincs, $noclass) = calc_lincRNAs($p_gtf, $p_ncRNAs, $c_ncRNAs, $refAnnot, $u_ncRNAs);
	}

	# Numbers may have changed. Redo counts.
	# Remove categories that do not sync with cuffcompare.
    
	if (!defined $rescue) {
	    
	    my $c_no_ncRNAs = $u_ncRNAs;
	    my $c_ncRNAs_tmp = $c_ncRNAs . '.tosync';
	    $io->execute_system_command("cp $c_ncRNAs $c_ncRNAs_tmp") if (-e $c_ncRNAs && !-e $c_ncRNAs_tmp);
	    
	    $io->error("Cannot find *.tosync file while attempting to sync lncRNA categories.\n" . 
		       'This may also mean that 0 transcripts have been categorized.')
		if (!-e $c_ncRNAs_tmp || !-s $c_ncRNAs_tmp);
	    
	    my $c_ncRNAs_tmp_fh = $io->open_file('<', $c_ncRNAs_tmp);
	    my $c_ncRNAs_fh = $io->open_file('>', $c_ncRNAs);
	    my $c_no_ncRNAs_fh = $io->open_file('>>', $c_no_ncRNAs);
	    
	    while (my $line = <$c_ncRNAs_tmp_fh>) {
		if ($line =~ m/.+?class_code\s+\W[jxo].+?exonic\s*overlap/i ||
		    $line =~ m/.+?class_code\s+\Wu.+?LincRNA/i ||
		    $line =~ m/.+?class_code\s+\Wi.+?\WInc\s*\-/i ||
		    $line =~ m/.+?class_code\s+\W[jxo].+?Ponc/i ||
		    $line =~ m/.+?class_code\s+\W[jxo].+?Conc/i
		    ) {
		    print $c_ncRNAs_fh $line;
		}
		elsif (defined $known_ncRNAs) {
		    print $c_ncRNAs_fh $line;
		}
		else {
		    print $c_no_ncRNAs_fh $line;
		}
	    }
	    
	    close $c_ncRNAs_tmp_fh;
	    close $c_ncRNAs_fh;
	    close $c_no_ncRNAs_fh;
	    unlink $c_ncRNAs_tmp if (-e $c_ncRNAs_tmp);
	    
	    chomp ($num_lincs = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t.+?lncRNA_type.+?lincrna' $c_ncRNAs | wc -l"));
	    $num_lincs = 0 if ($num_lincs =~ m/^could not capture/i);
	    
	    chomp ($num_concs = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t.+?lncRNA_type.+?conc' $c_ncRNAs | wc -l"));
	    $num_concs = 0 if ($num_concs =~ m/^could not capture/i);
	    
	    chomp ($num_poncs = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t.+?lncRNA_type.+?ponc' $c_ncRNAs | wc -l"));
	    $num_poncs = 0 if ($num_poncs =~ m/^could not capture/i);
	    
	    chomp ($num_incs = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t.+?lncRNA_type.+?inc.+?intronic' $c_ncRNAs | wc -l"));
	    $num_incs = 0 if ($num_incs =~ m/^could not capture/i);
	    
	    chomp ($num_ex_ov = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t.+?lncRNA_type.+?exonic\\s+overlap' $c_ncRNAs | wc -l"));
	    $num_ex_ov = 0 if ($num_ex_ov =~ m/^could not capture/i);
	    
	    chomp ($noclass = $io->execute_get_sys_cmd_output("grep -iP '\ttranscript\t' $u_ncRNAs | wc -l"));
	    $noclass = 0 if ($noclass =~ m/^could not capture/i);
	}
	    
	$io->c_time("\n\nlncRNA Summary [ " . $io->file_basename($c_ncRNAs, 'suffix') . " ] :\n" . 
		    "-----------------------------------------------------------------------\n" .
		    "Total number of input transcripts: $total_nc_trs_before_cat\n" .
		    "LincRNAs: $num_lincs\n" . 
		    "Intronic overlaps - Concs: $num_concs\n" .
                    "Intronic overlaps - Poncs: $num_poncs\n" . 
		    "Intronic overlaps - Incs: $num_incs\n" . 
		    "Exonic overlaps: $num_ex_ov\n" . 
		    "Total categorized: " . ($num_lincs + 
					     $num_concs + 
					     $num_incs + 
					     $num_ex_ov +
					     $num_poncs) . 
		    "\nUncategorized: " . 
		    $noclass . "\n" );
	
	$cpu->finish if (defined $num_cpu);
    }

    $cpu->wait_all_children if (defined $num_cpu);
    return;
}

# Calculate LincRNAs
sub calc_lincRNAs {
    my $p_gtf = shift;
    my $p_ncRNAs = shift;
    my $c_ncRNAs = shift;
    my $refAnnot = shift;
    my $u_ncRNAs = shift;
    my $found = 0;
    my $num_noClass = 0;

    foreach my $chr (keys %{$refAnnot}) {
	my $ref_gene_tree = Set::IntervalTree->new();
	my $lincRNA_prox_ref_gene_tree = Set::IntervalTree->new()
	    if (defined $linc_rna_prox && $linc_rna_prox > 0);
	   
	foreach my $ref_gene (values @{$refAnnot->{$chr}}) {
	    my ($ref_strand,
		$ref_tr_start,
		$ref_tr_end,
		$ref_exons,
		$ref_exon_starts,
		$ref_exon_ends,
		$ref_tr_id) = get_parts($ref_gene);
	    
	    if (defined $linc_rna_prox && $linc_rna_prox > 0) {
		if ($ref_tr_start != 0 ) {
		    $lincRNA_prox_ref_gene_tree->insert($ref_tr_id . 'lincRNA_prox_st',
							$ref_tr_start - $linc_rna_prox,
							$ref_tr_start - 1);
		}
		$lincRNA_prox_ref_gene_tree->insert($ref_tr_id . 'lincRNA_prox_end',
						    $ref_tr_end + 1,
						    $ref_tr_end + $linc_rna_prox);
	    }
	    else {
		$ref_gene_tree->insert($ref_tr_id, $ref_tr_start, $ref_tr_end);
	    }
	} 
	
	foreach my $transfrag (values @{$p_ncRNAs->{$chr}}) {
	    my ($nc_strand,
		$nc_tr_start,
		$nc_tr_end,
		$nc_exons,
		$nc_exon_starts,
		$nc_exon_ends,
		$nc_tr_id) = get_parts($transfrag);
	 
	    my $unique_key = "$nc_tr_id$nc_strand$nc_tr_start$nc_tr_end$nc_exons" . join('', @$nc_exon_starts) . join('', @$nc_exon_ends);
	
	    # Skip if non-coding transcript length is more than user defined max length
	    my $ncRNA_length = this_tr_len($nc_exon_starts, $nc_exon_ends);

	    $io->error("Exon start [ $nc_tr_start ] is greater than Exon end [ $nc_tr_end  ] for $nc_tr_id")
		if ($ncRNA_length < 0);

	    $io->error("Could not get transcript length for $nc_tr_id in [ " . $io->file_basename($p_ncRNAs, 'suffix')) . " ] ..."
		if ($ncRNA_length == 0);

	    next if ( (defined $ncRNA_max_length) && ($ncRNA_length > $ncRNA_max_length) );
	   
	    my $ov_found = $ref_gene_tree->fetch($nc_tr_start, $nc_tr_end);

	    if (defined $linc_rna_prox &&
		$linc_rna_prox > 0) {
		
		my $lincRNA_prox_ov_found = $lincRNA_prox_ref_gene_tree->fetch($nc_tr_start, $nc_tr_end);
		
		if (scalar(@$ov_found) == 0 &&
		    scalar(@$lincRNA_prox_ov_found) == 1 &&
		    !exists $ncRNA_class->{$unique_key} &&
		    $ncRNA_length >= $length &&
		    $nc_exons >= $min_exons) {
		    $found++;
		    $ncRNA_class->{$unique_key} = 1;
		    
		    $io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"LincRNA\";\/\' >> $c_ncRNAs", 0);
		}
		elsif (!exists $ncRNA_class->{$unique_key} &&
		       $ncRNA_length >= $length &&
		       $nc_exons >= $min_exons) {
		    $num_noClass++;
		    $ncRNA_class->{$unique_key} = 1;
		    $io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"No Class \(\?\)\"\;\/\' >> $u_ncRNAs", 0);
		}
		next;
	    }

	    if (scalar(@$ov_found) == 0 &&
		!exists $ncRNA_class->{$unique_key} &&
		$ncRNA_length >= $length &&
		$nc_exons >= $min_exons) {
		$found++;
		$ncRNA_class->{$unique_key} = 1;
		$io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"LincRNA\";\/\' >> $c_ncRNAs", 0);
	    }
	    elsif (!exists $ncRNA_class->{$unique_key} &&
		   $ncRNA_length >= $length &&
		   $nc_exons >= $min_exons) {
		$num_noClass++;
		$ncRNA_class->{$unique_key} = 1;
		$io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"No Class \(\?\)\"\;\/\' >> $u_ncRNAs", 0);
	    }
	}
    }
    return ($found, $num_noClass);
}

# Calcualte overlaps of putative ncRNAs with reference information.
sub calc_overlaps {
    my $mode = shift;
    my $p_gtf = shift;
    my $p_ncRNAs = shift;
    my $c_ncRNAs = shift;
    my $refAnnot = shift;
    my $u_ncRNAs = shift;
    my $found = 0;
    my $num_noSense = 0;

    foreach my $nc_chr (keys %{$p_ncRNAs}) {

	my $nc_int_tree = Set::IntervalTree->new() if ($mode =~ m/^ponc|conc$/i);
	    
	for (my $ncRNA_line=0; $ncRNA_line <= $#{$p_ncRNAs->{$nc_chr}}; $ncRNA_line++) {
	    	  
	    my ($nc_strand,
		$nc_tr_start,
		$nc_tr_end,
		$nc_exons,
		$nc_exon_starts,
		$nc_exon_ends, 
		$nc_tr_id) = get_parts($p_ncRNAs->{$nc_chr}->[$ncRNA_line]);

	    my $unique_key = "$nc_tr_id$nc_strand$nc_tr_start$nc_tr_end$nc_exons" . join('', @$nc_exon_starts) . join('', @$nc_exon_ends);

	    # Skip if non-coding transcript length is more than user defined max length
	    my $ncRNA_length = this_tr_len($nc_exon_starts, $nc_exon_ends);
	    
	    $io->error("Exon start [ $nc_tr_start ] is greater than Exon end [ $nc_tr_end  ] for $nc_tr_id")
		if ($ncRNA_length < 0);
	    
	    $io->error("Could not get transcript length for $nc_tr_id in [ " . $io->file_basename($p_ncRNAs, 'suffix')) . " ] ..."
		if ($ncRNA_length == 0);

	    next if ( (defined $ncRNA_max_length) && ($ncRNA_length > $ncRNA_max_length) );

	    $nc_int_tree->insert($nc_tr_id, $nc_tr_start, $nc_tr_end) if ($mode =~ m/^ponc|conc$/i);

	    foreach my $ref_gene (values @{$refAnnot->{$nc_chr}}) {
		
		my ($ref_strand, 
		    $ref_tr_start, 
		    $ref_tr_end, 
		    $ref_exons, 
		    $ref_exon_starts, 
		    $ref_exon_ends,
		    $ref_tr_id) = get_parts($ref_gene);
		
		my $is_strand_Antisense = is_Antisense($ref_strand, $nc_strand);

		# Only lncRNAs, adjustable by user with -length and -min-exons parameters.
		if ($ncRNA_length >= $length &&
		    $nc_exons >= $min_exons) { 

		    # Complete overlap reference gene with ncRNA intron.
		    if ($mode =~ m/^conc$/i &&
                        $nc_tr_start < $ref_tr_start &&
			$nc_tr_start < $ref_tr_end &&
                        $nc_tr_end > $ref_tr_start &&
			$nc_tr_end > $ref_tr_end) {

			my $ov_tr_found = $nc_int_tree->fetch($ref_tr_start ,$ref_tr_end);
			my $is_ncRNA_Conc = is_intronicOverlap($ref_tr_start, $ref_tr_end, $nc_exon_starts, $nc_exon_ends);
			
			if ($is_ncRNA_Conc &&
			    $is_strand_Antisense &&
			    scalar(@$ov_tr_found) >= 1 &&
			    !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Conc - Antisense intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Conc &&
			       !$is_strand_Antisense &&
			       scalar(@$ov_tr_found) >= 1 &&
			       !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Conc - Sense intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
                            $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Conc &&
			       scalar(@$ov_tr_found) >= 1 &&
			       !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Conc - Intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
		    }
		    		    
		    # Complete overlap of ncRNA within reference intron	
		    if ($mode =~ m/^inc$/i &&
			$nc_tr_start > $ref_tr_start &&
			$nc_tr_start < $ref_tr_end &&
                        $nc_tr_end < $ref_tr_end &&
			$nc_tr_end > $ref_tr_start) {
			
			my $is_ncRNA_Inc = is_intronicOverlap($nc_tr_start, $nc_tr_end, $ref_exon_starts, $ref_exon_ends);
			
			if ($is_ncRNA_Inc &&
			    $is_strand_Antisense &&
			    !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Inc - Antisense intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Inc &&
			       !$is_strand_Antisense &&
			       !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Inc - Sense intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Inc &&
			       !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Inc - Intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
		    }

		    # Antisense and Sense partial reference intronic overlap.
		    if ($mode =~ m/^ponc$/i &&
			(( ($nc_tr_start > $ref_tr_start) &&
			   ($nc_tr_end > $ref_tr_end) &&
			   ($nc_tr_start < $ref_tr_end) &&
			   ($nc_tr_end > $ref_tr_start)
			 ) || 
			 ( ($nc_tr_start < $ref_tr_start) &&
			   ($nc_tr_end < $ref_tr_end) &&
			   ($nc_tr_start < $ref_tr_end) &&
			   ($nc_tr_end > $ref_tr_start)
			 ))
			) {
			 
			my $is_ncRNA_Inc = is_intronicOverlap($ref_tr_start, $ref_tr_end, $nc_exon_starts, $nc_exon_ends);
			my $found_intron_ov = $nc_int_tree->fetch($ref_tr_start, $ref_tr_end);
			my $is_ncRNA_exonicOverlap = is_exonicOverlap($ref_exon_starts, $ref_exon_ends, $nc_exon_starts, $nc_exon_ends);
			my $retain_overlap = $overlap;
			$overlap = 0;
			
			if ($is_ncRNA_Inc &&
			    !$is_ncRNA_exonicOverlap &&
			    $is_strand_Antisense &&
			    !exists $ncRNA_class->{$unique_key} &&
			    scalar(@$found_intron_ov) >= 1) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Ponc - Antisense partial intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Inc &&
			       !$is_ncRNA_exonicOverlap &&
			       !$is_strand_Antisense &&
			       !exists $ncRNA_class->{$unique_key} &&
			       scalar(@$found_intron_ov) >= 1) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Ponc - Sense partial intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_Inc &&
			       !$is_ncRNA_exonicOverlap &&
			       !exists $ncRNA_class->{$unique_key} &&
			       scalar(@$found_intron_ov) >= 1) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Ponc - Partial intronic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			$overlap = $retain_overlap;
		    }
		    
		    # Antisense and Sense reference exonic overlap.
		    if ($mode =~ m/^exonic$/i) {
			
			my $is_ncRNA_exonicOverlap = is_exonicOverlap($ref_exon_starts, $ref_exon_ends, $nc_exon_starts, $nc_exon_ends);

			if ($is_ncRNA_exonicOverlap &&
			    $is_strand_Antisense &&
			    !exists $ncRNA_class->{$unique_key}) {
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Exonic - Antisense exonic overlap with $ref_tr_id\";";
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $found++;
			    last;
			}
			elsif ($is_ncRNA_exonicOverlap &&
			       !$is_strand_Antisense &&
			       !exists $ncRNA_class->{$unique_key}) {
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--; 
			    $num_noSense++,
			    $io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"Exonic - Sense exonic overlap with $ref_tr_id\";\/\' >> $u_ncRNAs", 0),
			    last if (defined($antisense_only) && $antisense_only);
			    $found++;
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Exonic - Sense exonic overlap with $ref_tr_id\";";
			    last;
			}
			elsif ($is_ncRNA_exonicOverlap &&
			       !exists $ncRNA_class->{$unique_key}) {
			    splice(@{$p_ncRNAs->{$nc_chr}}, $ncRNA_line, 1);
			    $ncRNA_line--;
			    $num_noSense++,
			    $io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; lncRNA_type \"Exonic - Exonic overlap with $ref_tr_id\";\/\' >> $u_ncRNAs", 0),
			    last if (defined($antisense_only) && $antisense_only);
			    $found++;
			    $ncRNA_class->{$unique_key} = "lncRNA_type \"Exonic - Exonic overlap with $ref_tr_id\";";
			    last;
			}
		    }
		}
	    }
	    
	    # All ncRNAs that have been categorized will be here. The remaning will go through lincRNAs or noClass check.
	    if (exists $ncRNA_class->{$unique_key}) {
		$io->execute_system_command('grep -P \'transcript_id\s+\"' . $nc_tr_id . '\"\' '  . "$p_gtf | sed -e \'s\/\$\/ transcript_length \"$ncRNA_length\"\; $ncRNA_class->{$unique_key}\/\' >> $c_ncRNAs", 0);
	    }
	}
    }
    return ($found, $num_noSense);
}

# Return transcript length
sub this_tr_len {
    my $exon_starts = shift;
    my $exon_ends = shift;

    $io->error('Number of Exon starts do not correspond with number of Exon ends.')
	if ($#$exon_starts != $#$exon_ends);
    
    my $tr_len = 0;
    for (my $ith_exon=0; $ith_exon<=$#$exon_starts; $ith_exon++) {
	# gtfToGenePred already decreases exon start by, so no need of +1
	$tr_len = $tr_len + ($exon_ends->[$ith_exon] - $exon_starts->[$ith_exon]);
    }

    return $tr_len if ($tr_len > 0);
    return 0;
}

# Store genome coordinates.
sub store_coords {
    my $f = shift;
    my $fh = $io->open_file('<', $f);
    my $store = {};

    $io->c_time('Reading information from gene prediction format file [ ' . 
		$io->file_basename($f, 'suffix') . ' ]...');
    while (my $line = <$fh>) {
	chomp $line;
	$line = $io->strip_leading_and_trailing_spaces($line);
	my ($t_id, $chr, $strand, $tr_start, $tr_end,
	    $cds_start, $cds_end, $num_exons, $exon_starts, $exon_ends, @rem) = split/\t/, $line;
	$exon_starts =~ s/\,$//;
	$exon_ends =~ s/\,$//;

	# This is not necessary. Now no confusion for ENSEMBL annotations.
	#$chr = "chr$chr" if ($line =~ m/^ens/i && $strand =~ m/^\+|\-|\.$/ && $num_exons =~ m/\d+/ && $chr !~ m/^chr/);

	if (!defined $ignore_genePred_err) {
	    $io->error('Supplied file [ ' . $io->file_basename($f, 'suffix') . ' ] does not seem to be in gene prediction format...' .
		       "\n\nError occured on line:\n\n$line\n\nUse --ignore-genePred-err option to skip this check if you think this is a valid line.\n")
		if ($chr !~ m/^(chr|ens|uc)/i || $strand !~ m/^\+|\-|\.$/ || $num_exons !~ m/\d+/);
	}
	
	push @{$store->{lc($chr)}}, "$strand|$tr_start|$tr_end|$cds_start|$cds_end|$num_exons|$exon_starts|$exon_ends|$t_id";
    }
    return $store;
}

# Split and return columns.
sub get_parts {
    my @line_parts = split /\|/, shift;
    $line_parts[8] =~ s/\./\\./g;
    
    return ($line_parts[0],
	    $line_parts[1],
	    $line_parts[2],
	    $line_parts[5],
	    [split /\,/, $line_parts[6]],
	    [split /\,/, $line_parts[7]],
	    $line_parts[8]);
}

# Calculate exonic overlap.
sub is_exonicOverlap {
    my ($s_ex_st, $s_ex_end, $c_ex_st, $c_ex_end) = @_;

    my $exon_match_count = 0;
    
    for (0 .. $#$c_ex_st) {

	my $nc_ex_coord = $_;
	my $c_ex_len = $c_ex_end->[$nc_ex_coord] - $c_ex_st->[$nc_ex_coord];
	
	for (0 .. $#$s_ex_st) {

	    my $s_ex_len = $s_ex_end->[$_] - $s_ex_st->[$_];
	    my $ex_ov_per = ($c_ex_len / $s_ex_len) * 100;
	    
	    if ($c_ex_st->[$nc_ex_coord] <= $s_ex_st->[$_] && 
		$c_ex_st->[$nc_ex_coord] <= $s_ex_end->[$_] && 
		$c_ex_end->[$nc_ex_coord] >= $s_ex_st->[$_] && 
		$c_ex_end->[$nc_ex_coord] <= $s_ex_end->[$_]) {
		return 1 if ( defined($overlap) && ($ex_ov_per >= $overlap) && !defined $known_ncRNAs);
		$exon_match_count++;
	    }
	    elsif ($c_ex_st->[$nc_ex_coord] >= $s_ex_st->[$_] &&
		   $c_ex_st->[$nc_ex_coord] <= $s_ex_end->[$_] &&
		   $c_ex_end->[$nc_ex_coord] >= $s_ex_st->[$_] &&
		   $c_ex_end->[$nc_ex_coord] <= $s_ex_end->[$_]) {
		return 1 if ( defined($overlap) && ($ex_ov_per >= $overlap) && !defined $known_ncRNAs);
		$exon_match_count++;
	    }
	    elsif ($c_ex_st->[$nc_ex_coord] >= $s_ex_st->[$_] &&
		   $c_ex_st->[$nc_ex_coord] <= $s_ex_end->[$_] &&
		   $c_ex_end->[$nc_ex_coord] >= $s_ex_st->[$_] &&
		   $c_ex_end->[$nc_ex_coord] >= $s_ex_end->[$_]) {
		return 1 if ( defined($overlap) && ($ex_ov_per >= $overlap) && !defined $known_ncRNAs);
		$exon_match_count++;
	    }
	    elsif ($c_ex_st->[$nc_ex_coord] <= $s_ex_st->[$_] &&
		   $c_ex_st->[$nc_ex_coord] <= $s_ex_end->[$_] &&
		   $c_ex_end->[$nc_ex_coord] >= $s_ex_st->[$_] && 
		   $c_ex_end->[$nc_ex_coord] >= $s_ex_end->[$_]) {
		return 1 if ( defined($overlap) && ($ex_ov_per >= $overlap) && !defined $known_ncRNAs);
		$exon_match_count++;
	    }
	}
    }

    return 1 if (defined $known_ncRNAs &&
		 ( ($exon_match_count - 1) == $#$c_ex_st)
		 #&& ( this_tr_len($c_ex_st, $c_ex_end) ==  this_tr_len($s_ex_st, $s_ex_end) )
	);

    return 0;
}

# Calculate ncRNA intronic overlap with reference gene information for Concs, Poncs and Incs.
sub is_intronicOverlap {
    my ($tr_start, $tr_end, 
	$ex_st, $ex_end) = @_;
    
    # Return false if it is only single exon transcript.
    return 0 if ($#$ex_st == 0);

    for (1 .. $#$ex_st) {
	my $prev_exon_end = $_ - 1;
	return 1 if ($tr_end < $ex_st->[$_] &&
		     $tr_start > $ex_end->[$prev_exon_end]);
	
	#return 1 if ( ($tr_end - $tr_start) < ($ex_st->[$_] - $ex_end->[$prev_exon_end]) )
    }
    return 0;
}

# Calculate strandedness.
sub is_Antisense {
    my ($ref_strand, $comp_strand) = @_;

    if ($ref_strand ne $comp_strand &&
	$ref_strand =~ m/^\+|\-$/ &&
	$comp_strand =~ m/^\+|\-$/) {
	return 1;
    } 
    return 0;
}

# Remove warnings
sub remove_warnings {
    my $msg = shift;
    $io->c_time($msg);
    unlink $output . '.cat_fpkm_cutoff.war' if (-e $output . '.cat_fpkm_cutoff.war');
    unlink $output . '.cat_cov_cutoff.war' if (-e $output . '.cat_cov_cutoff.war');
    unlink $output . '.cat_full_read_supp.war' if (-e $output . '.cat_full_read_supp.war');
    return;
}

# Check GTF attribute column
sub check_gtf_attributes {
    my $file = shift;
    my $label = shift;
    my $t_lines_tr = $io->execute_get_sys_cmd_output('grep -iP \'\ttranscript\t.+?transcript_id\' ' . $file .' | head -n 1');
    my $t_lines_ex = $io->execute_get_sys_cmd_output('grep -iP \'\texon\t.+?transcript_id\' ' . $file .' | head -n 1');
    
    if ( ($t_lines_tr !~ m/\".+?\"\;/ && $t_lines_ex !~ m/\".+?\"\;/) ||
	 ($t_lines_tr =~ m/\'.+?\'/ || $t_lines_ex =~ m/\'.+?\'/)
	) {
	$io->error('The attribute column of GTF file does not contain tag-value pairs between double quotes [ Ex: gene_id "CUFF.1"; ].' .
	    "\nError occured on one of the following lines [ in " . $file . " ]:\n\n$t_lines_tr\n\n$t_lines_ex");
    }
    
    if (!$t_lines_tr || $t_lines_tr =~ m/^could/i || $t_lines_tr =~ m/STDERR/i) {
	$io->warning('Seems like the suppiled assembly [ ' . $io->file_basename($file, 'suffix') . ' ] file does not contain proper transcript-exon features.' .
		   "\nIt should have a transcript feature line followed by it's exon feature lines.\n\nExample:\n--------\n".
		   qq/chr3\tCufflinks\ttranscript\t30549662\t30551349\t1000\t-\t.\tgene_id "CUFF.22498"; transcript_id "CUFF.22498.1"; FPKM "2.5052666329"; frac "1.000000"; conf_lo "1.676755"; conf_hi "3.353509"; cov "4.749121";\n/ .
		   qq/chr3\tCufflinks\texon\t30549662\t30550273\t1000\t-\t.\tgene_id "CUFF.22498"; transcript_id "CUFF.22498.1"; exon_number "1"; FPKM "2.5052666329"; frac "1.000000"; conf_lo "1.676755"; conf_hi "3.353509"; cov "4.749121";\n/ .
		   qq/chr3\tCufflinks\texon\t30551033\t30551349\t1000\t-\t.\tgene_id "CUFF.22498"; transcript_id "CUFF.22498.1"; exon_number "2"; FPKM "2.5052666329"; frac "1.000000"; conf_lo "1.676755"; conf_hi "3.353509"; cov "4.749121";\n/ .
		     qq/\nYour File:\n----------\n/ . $io->execute_get_sys_cmd_output("head -n 3 $file"), 'INFO!!');
	$io->warning('Sit back and relax. We got it covered ... Formatting the GTF file to process with lncRNApipe.', 'INFO!!');
	$file = format_gtf($file, $label);
    }
    return $file;
}

# Format all the exon "only" features to "transcript-exon" in the GTF file.
sub format_gtf {
    my $gtf = shift;
    my $label = shift;
    my $gtf_fh = $io->open_file('<', $gtf);
    my $formatted_gtf = $output . $io->file_basename($gtf) . ".$label.formatted.gtf";
    my $formatted_gtf_fh = $io->open_file('>', $formatted_gtf);
    my $tr_ids = {};
    my $tr_lines = {};

    while (my $line = <$gtf_fh>) {
	chomp $line;
	$io->error('Did not find "transcript_id" tag-value pair in the GTF file [ ' . $io->file_basename($gtf) . ' ].' .
		   "\nError occured on the following line:\n\n" . $line . "\n")
	    if ($line !~ m/.+?transcript_id\s+\".+?\"/i);
	$line =~ s/class_code\s+\W.+?\W+//;
	(my $transcript_id) = ($line =~ m/.+?transcript_id\s+\"(.+?)\"/i);
	my @gtf_cols = split/\t/, $line;
	push @{$tr_ids->{$transcript_id}}, $gtf_cols[3];
	push @{$tr_ids->{$transcript_id}}, $gtf_cols[4];
	push @{$tr_lines->{$transcript_id}}, "$line\n";
    }
    close $gtf_fh;

    foreach my $tr_id (keys %$tr_ids) {
	my @bounds = sort { $a <=> $b } @{$tr_ids->{$tr_id}};
	my $tr_line = @{$tr_lines->{$tr_id}}[0];
	if ($tr_line =~ m/exon\_number/i) { 
	    $tr_line =~ s/(.+?\t.+?\t)exon(\t)\d+\t\d+(.+?)exon_number\s+\W\d+\W+(.*)/$1transcript$2$bounds[0]\t$bounds[$#bounds]$3$4/;
	}
	else {
	    $tr_line =~ s/(.+?\t.+?\t)exon(\t)\d+\t\d+(.*)/$1transcript$2$bounds[0]\t$bounds[$#bounds]$3/;
	}
	print $formatted_gtf_fh $tr_line;
	print $formatted_gtf_fh @{$tr_lines->{$tr_id}};
    }
    
    $gtf_formatted = 1;
    return $formatted_gtf;
}

# Exit if we do not have any cuffcompare class codes.
sub check_for_zero_class {
    for (0 .. $#ARGV) {
	if (-e $get_putative_ncRNAs_chkpt && !-e $p_file_names_gtf->[$_]) {
	    #$io->warning("We could not find any requested class codes [ in $cuffcmp ] ...\nBailing out!");
	    $io->execute_system_command("touch $cat_class_zero");
	    exit 0;
	}
    }
    return;
}

__END__

=head1 NAME

categorize_ncRNAs.pl

=head1 SYNOPSIS

This script will categorize the Cufflinks' assembled transcripts into ncRNA classes as mentioned 
in the paper: http://genome.cshlp.org/content/22/3/577.full. 

=head2 DOCUMENTATION

    perldoc categorize_ncRNAs.pl

=head3 EXAMPLES:

    perl categorize_ncRNAs.pl -min-exons 1 -fpkm 2 -length 200 -annotation refSeq_ucscKnown_ensemble.txt -sample-names 'M0,M1,M2' -out lncRNA -cuffcmp cuffcmp.tracking m0/transcripts.gtf m1/transcripts.gtf m2/cufflinks/transcripts.gtf

=head1 DESCRIPTION

Cufflinks includes a program called Cuffcompare, which will compare the transcripts generated 
across all the samples with provided reference annotation of choice and generates class code 
for each of the assembled transcripts, while tracking the transcripts at the respective loci in 
each sample. This script will take in the Cuffcompare tracking file and the corresponding assembled 
transcripts for each sample in GTF format and produces a putative list of novel ncRNAs and categorizes
them as mentioned in the paper (http://genome.cshlp.org/content/22/3/577.full). Best results can be 
obtained when all the known annotation resources are combined. For organisms like Human and Mouse, 
combining RefSeq, UCSC Known genes and Ensembl genes can help filter a lot of known protein-coding 
genes and known ncRNAs. When Cufflinks' assembled transript files are supplied in GTF format, they
are first converted to Gene Prediction format using gtfToGenePred tool from UCSC, which can be downloaded
from http://hgdownload.cse.ucsc.edu/admin/exe. The tool is flexible and can resume in parts as mentioned
in the OPTIONS' section.

=head3 OUTPUT:

The final output is written to *.putative.class.gtf files and depends upon number of Cufflinks assembled transcript files
supplied.

=head2 WARNING

The assembled transcripts' files supplied to this program must be in the exact order as supplied to Cuffcompare program
while creating the *.tracking file. For example if this is your Cuffcompare call:

cuffcompare -R -r reference.gtf -o lncRNApipe_cuffcompare transcripts1_input.gtf transcripts2_input.gtf

then, the same order must be preserved while calling categorize_ncRNAs.pl. Example:

categorize_ncRNAs.pl . . . . transcripts1_input.gtf transcripts2_input.gtf

=head2 KNOWN ISSUES

The annotation should be in the Gene Prediction format. When Gene Prediction format files for RefSeq
are downloaded from UCSC, the first column is generally a "bin" id unique to SQL table from UCSC. This
column *MUST* be removed prior to using it as an annotation file. This can be done using the "cut"
command.

Ex: cut -f 2- refGene.txt > refGene.nobin.txt

=head1 OPTIONS

categorize_ncRNAs.pl takes the following arguments:

=over 4

=item -h or --help (Optional)

    Displays this helpful message.

=item -q or --quiet (Optional)

    Turn off logging.

=item -cuff or --cuffcmp (Required)

    Path to Cuffcompare tracking file.
    
    Ex: cuffcmp.tracking

=item -annot or --annotation (Required)

    Path to annotation file in Gene Prediction format.
    
    Ex: refGene.txt

=item --out (Required)

    Path to output directory.

=item -sample or --sample-names (Required)

    Sample names in order of supplied transcripts files.
  
    Ex: --sample-names 'Sample1,Sample2,Sample3';

=item -rescue or --rescue-categories (Optional)

    Keep the transcripts that have been assigned a category that is
    different from cuffcompare assigned class code.
    
    Ex: class_code "i" means, A transfag falling entirely within reference intron.
    If categorize_ncRNAs.pl assigns other than "Intronic" category to this transcript,
    this option will still keep it. This may be useful sometimes to investigate 
    incorrect class_code and lncRNA categories.

=item -fpkm or --fpkm-cutoff (Optional)

    Default: disabled

    Extract transcript features whose FPKM / RPKM value is at least this much.
    This can be a floating point value.

=item -cov or --cov-cutoff (Optional)

    Default: disabled

    Extract transript features whose coverage is at least this much. This
    can be a floating point value.

=item -full or --full-read-support (Optional)

    Default: disabled

    Extract Cufflinks' transcripts whose value full_read_support is "yes".

=item -inc or --include-novel (Optional)

    Default: disabled

    By default, transcript features belonging to class codes "x", "o", "i" and "u"
    are extracted. Providing this option also extracts Cufflinks transcripts 
    classified as novel ("j") isoforms.

=item -gene or -genePred (Optional)

    Default: disabled

    The script first extracts transcripts that belong to the Cufflinks'
    class codes "x", "o", "i" and "u" or class codes "x", "o", "i", "u"
    and "j" and generates the respective *putative_lncRNAs.gtf files.
    If for any reason the script fails on moving forward, it can be 
    asked to skip the extraction step and resume from converting the 
    *putative_lncRNAs.gtf files to Gene Prediction format and then 
    the categorization step with this option.

=item -cat or --categorize (Optional)

    Default: disabled

    Providing this option skips the extraction and convertion steps and
    continues the pipeline from categorizing putative lncRNAs.

=item -len or --length (Optional)

    Default: 200

    Extract transcripts whose length is at least this much.

=item -max-len or --max-length (Optional)

    Default: disabled

    Extract transcripts whose length is not more than this much.

=item -min or --min-exons (Optional)

    Default: 2

    Extract transcripts which contain at least this many number of exons.

=item -ov or --overlap (Optional)

    Default: disabled

    When calculating exonic overlaps with reference exon boundaries, consider
    it as an exonic overlap if the Cufflinks assembled transcripts' exon overlaps
    with reference exon by at least this much percentage. This can be floating 
    point value.

=item -clean or --clean-tmp (Optional)

    Default: disabled

    Remove intermediate files. Specifically, *putative_lncRNAs.gtf and
    *putative_lncRNAs.txt files are removed.

=item -anti or --antisense (Optional)

    Default: disabled
    
    When reporting exonic overlaps with reference exons, report only Antisense
    exonic overlaps.

=item --linc-rna-prox (Optional)

    Default: disabled

    When reporting Long intergenic ncRNAs, report only those which are within this
    many number of bases upstream or downstream of the reference gene.

=item --ignore-genePred-err (Optional)

    Default: disabled

    The program first stores the reference information from Gene Prediction format
    into memory while verifying the validity of Gene Prediction format and exits
    with an error if it cannot validate. Use this option if you think the Gene Prediction
    format of the file you supplied is correct but in any case, this program thinks otherwise.

=item --known-ncRNAs (Optional)

    Using this option will cause the program to compare transcripts to known ncNRAs supplied
    in GTF format to extract any known ncRNAs constructed by transcriptome assemblers in your 
    data.

=item --extract-pat (Optional)

    Default: 'i|o|u|x|e'

    The script first extracts transcripts that belong to the Cufflinks'
    class codes "x", "o", "i" and "u" or class codes "x", "o", "i", "u" and "j" 
    and generates the respective *putative_lncRNAs.gtf files.
    If you want to extract transcripts belonging to class codes
    of your choice, use this option. For example, if you only
    want trancripts belonging to class codes i and u, use:

    --extract-pat 'i|u'

=item -cpu or --cpu (Optional)

    Default: 1
    
    Use this many number of CPUs to run in parallel.

=back

=head1 AUTHOR

Kranti Konganti, E<lt>konganti@tamu.eduE<gt>.

=head1 COPYRIGHT

This program is distributed under the Artistic License 2.0.

=head1 DATE

Feb-20-2018

=cut
