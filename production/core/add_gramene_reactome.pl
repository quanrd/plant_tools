#!/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);;
use Bio::EnsEMBL::Registry;

# This script submits a reactome load job to hive
#
# It uses env $USER to create hive job names and assumes Ensembl-version API
# is loaded in @INC / $PERL5LIB
#
# Adapted from Dan Bolser's run_the_gramene_plant_reactome_loader_pipeline.sh
# by B Contreras Moreira 2019
#
## check user arguments ######################################################
##############################################################################

my %tricky_names = (
	'oryza_sativa_indica_group' => 'oryza_indica',
	'oryza_sativa_japonica_group' => 'oryza_sativa',
);

my $prodbname = 'ensembl_production_';
my $hive_db_cmd = 'mysql-ens-hive-prod-2-ensrw';
my $overwrite = 0;
my ($help,$reg_file,$sp,$species_cmd,$ensembl_version,$stats_only);
my ($xref_reac_file,$xref_path_file,$pipeline_dir);
my (@species,@db_names,$db);
my ($hive_args,$hive_url,$hive_db);

GetOptions(	
	"help|?" => \$help,
	"overwrite|w" => \$overwrite, 
	"version|v=s" => \$ensembl_version,
	"hivecmd|H=s" => \$hive_db_cmd,    
	"regfile|R=s" => \$reg_file,
	"reactions=s" => \$xref_reac_file,
	"pathways=s" => \$xref_path_file,
	"pipelinedir|P=s" => \$pipeline_dir,
	"statsonly|S" => \$stats_only,
	"species|s=s" => \@species,
	"prodb|D=s"   => \$prodbname
) || help_message(); 

if($help){ help_message() }

sub help_message {
	print "\nusage: $0 [options]\n\n".
	"-s species_name(s)                     (required, example: -s arabidopsis_thaliana -s ...)\n".
	"-reactions file                        (required, example: -reactions Ensembl2PlantReactomeReactions.txt)\n".
	"-pathways file                         (required, example: -pathways Ensembl2PlantReactome.txt)\n".
	"-v next Ensembl version                (required, example: -v 95)\n".
	"-R registry file, can be env variable  (required, example: -R \$p1panreg)\n".
	"-P pipeline dir, can be env variable   (required, example: -P \$dumptmp)\n".
        "-D ensembl_production db name          (optional, default: -D ensembl_production_Ensembl_version)\n".
	"-H hive database command               (optional, default: $hive_db_cmd)\n".
	"-w over-write db (hive_force_init)     (optional, useful when a previous run failed)\n".
	"-S check stats only                    (optional, does not load new data)\n\n";
	exit(0);
}

if($ensembl_version){
	# check Ensembl API is in env
	if(!grep(/ensembl-$ensembl_version\/ensembl-hive\/modules/,@INC)){
                die "# EXIT : cannot find ensembl-$ensembl_version/ensembl-hive/modules in \$PERL5LIB / \@INC\n"
        }
	$prodbname .= $ensembl_version;
}
else{ die "# EXIT : need a valid -v version, such as -v 95\n" } 

if(!$reg_file || !-e $reg_file){ 
	die "# EXIT : need a valid -R file, such as -R \$p1panreg\n"
} else {
	my $registry = 'Bio::EnsEMBL::Registry';
	$registry->load_all($reg_file);
	my $adaptors = $registry->get_all_DBAdaptors;
	for my $a (@$adaptors){
		push(@db_names, $a->dbc->dbname());
	}
}

if(!$pipeline_dir || !-e $pipeline_dir){
	die "# EXIT : need a valid -P folder to put pipeline files, such as -P \$dumptmp\n" 
} else {
	$pipeline_dir = "$pipeline_dir/$ensembl_version" 
}

if(@species){ # optional
        foreach $sp (@species){
                $species_cmd .= "-species $sp ";
        }
} else {
	die "# EXIT : need a valid -s species, such as -s arabidopsis_thaliana -s ...\n"
}

if(!$xref_reac_file || !-e $xref_reac_file){
	die "# EXIT : need a valid -r file, such as -r Ensembl2PlantReactomeReactions.txt\n"
}

if(!$xref_path_file || !-e $xref_path_file){
        die "# EXIT : need a valid -p file, such as -r Ensembl2PlantReactome.txt\n"
} else { 

	my (%supported);
	open(PATHS,"<",$xref_path_file) || 
		die "# ERROR: cannot read $xref_path_file\n";
	while(<PATHS>) {
		my @data = split(/\t/,$_); 
		next if(!$data[5]); 
		$sp = $data[5];	
		$sp = lc($sp);
                $sp =~ s/\s+/_/g;
                $sp =~ s/_+$//g;
		if($tricky_names{$sp}){ $sp = $tricky_names{$sp} }

		$supported{$sp}++;
		next if($supported{$sp} > 1); 
	
		if(scalar(@species) == 0){	
			$species_cmd .= "-species $sp ";
		}
	}
	close(PATHS);

	# check user's species
	foreach $sp (@species){
		if(!$supported{$sp}){
			die "# ERROR: -s $sp cannot be found in $xref_path_file, exit\n";
			exit;
		} else { 
			my $indb = 0;
			foreach $db (@db_names) {
				if($db =~ m/$sp/) {
					$indb = 1;
					last;
				}
			}

			if(!$indb){
				die "# ERROR: -s $sp cannot be found in server pointed by $reg_file, exit\n";
			}
		}
	}
}

chomp( $hive_args = `$hive_db_cmd details script` );
$hive_db = $ENV{'USER'}."_xref_gpr_$ensembl_version";
chomp( $hive_url  = `$hive_db_cmd --details url` );
$hive_url .= $hive_db;


## Run init script and produce a hive_db with all tasks to be carried out
#########################################################################

if(!$stats_only){
	my $initcmd = "init_pipeline.pl Bio::EnsEMBL::EGPipeline::PipeConfig::Xref_GPR_conf ".
    		"$hive_args ".
    		"-registry $reg_file ".
		"-production_db $prodbname ".
		"-pipeline_dir $pipeline_dir ".
    		"$species_cmd ".
		"-xref_reac_file $xref_reac_file ".
		"-xref_path_file $xref_path_file ".
		"-hive_force_init $overwrite";

	print "# $initcmd\n\n";
	
	open(INITRUN,"$initcmd |") || die "# ERROR: cannot run $initcmd\n";
	while(<INITRUN>){
		print;
	}
	close(INITRUN);
	
	## Send jobs to hive 
	######################################################################### 
	
	print "# hive job URL: $hive_url";
	
	system("beekeeper.pl -url '$hive_url;reconnect_when_lost=1' -sync");
	system("runWorker.pl -url '$hive_url;reconnect_when_lost=1' -reg_conf $reg_file");
	system("beekeeper.pl -url '$hive_url;reconnect_when_lost=1' -reg_conf $reg_file -loop");

	print "# hive job URL: $hive_url\n\n";
}

## post sanity checks
#########################################################################

my $registry = 'Bio::EnsEMBL::Registry';
$registry->load_all($reg_file);

my $sql_query = '
  SELECT
    db_name,
    COUNT(DISTINCT xref_id),
    COUNT(DISTINCT ensembl_id),
    COUNT(*)
  FROM
    external_db
  INNER JOIN
    xref        USING (external_db_id)
  INNER JOIN
    object_xref USING (xref_id)
  INNER JOIN
    gene ON ensembl_id = gene_id
  WHERE
    db_name = ?;
';

print "species\tdb_name\txref_ids\tensembl_ids\ttotal\n";
while($species_cmd =~ m/-species (\S+)/g){
	$sp = $1;
	my $dba = Bio::EnsEMBL::Registry->get_DBAdaptor($sp, "core");

	my $sth = $dba->dbc->prepare($sql_query);

	foreach my $external_db ( 'Plant_Reactome_Reaction', 'Plant_Reactome_Pathway'){ 
		$sth->execute($external_db);
		my @results = $sth->fetchrow_array;		
		print $sp;
		foreach my $n (@results) { print "\t$n" }
		print "\n";
	}
}

