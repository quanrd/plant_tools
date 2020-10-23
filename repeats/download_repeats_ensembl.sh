#!/usr/bin/env bash

# Script to download the annotated repeated elements of a selected
# Ensembl Plants species. 

# NOTE: required binaries: wget, bedtools, sort, perl, mysql, cd-hit-est

# Copyright [2020] EMBL-European Bioinformatics Institute

# documentation about Ensembl schemas can be found at 
# http://www.ensembl.org/info/docs/api/index.html

if [[ $# -eq 0 ]] ; then
	echo "# example usage: $0 arabidopsis_thaliana"
	exit 0
else
	SPECIES=$1
fi

# PARAMS
MINLEN=90
MAXDEGENPERC=10

# SERVER DETAILS
FTPSERVER="ftp://ftp.ensemblgenomes.org/pub"
DIV=plants
SERVER=mysql-eg-publicsql.ebi.ac.uk
USER=anonymous
PORT=4157

## 1) get Ensembl Plants current release number from FTP server
# Note: wget is used, this can be modified to use alternatives ie curl
SUMFILE="${FTPSERVER}/${DIV}/current/summary.txt"
RELEASE=`wget --quiet -O - $SUMFILE | \
	perl -lne 'if(/Release (\d+) of Ensembl/){ print $1 }'`

# work out Ensembl Genomes release
EGRELEASE=$(( RELEASE - 53));

## 2) select core db matching selected species
SPECIESCORE=$(mysql --host $SERVER --user $USER --port $PORT \
	-e "show databases" | grep "${SPECIES}_core_${EGRELEASE}_${RELEASE}")

## 3) retrieve 1-based coords of repeats

# note these might be redundant/overlapping
#1       3       106     trf
#1       4       91      trf

mysql --host $SERVER --user $USER --port $PORT $SPECIESCORE -Nb -e \
	"SELECT sr.name,r.seq_region_start,r.seq_region_end,rc.repeat_class \
	FROM repeat_feature r JOIN seq_region sr JOIN repeat_consensus rc \
	WHERE r.seq_region_id=sr.seq_region_id \
	AND r.repeat_consensus_id=rc.repeat_consensus_id \
	AND (r.seq_region_end-r.seq_region_start+1) > $MINLEN \
	ORDER BY sr.name,r.seq_region_start" > _${SPECIES}.repeats.bed

## 4) retrieve 1-based coords of genes 
mysql --host $SERVER --user $USER --port $PORT $SPECIESCORE -Nb -e \
	"SELECT sr.name,g.seq_region_start,g.seq_region_end,g.stable_id \
	FROM gene g JOIN seq_region sr \
	WHERE g.seq_region_id=sr.seq_region_id \
	ORDER BY sr.name,g.seq_region_start" > _${SPECIES}.genes.bed

## 5) curate repeats by substracting annotated genes
bedtools subtract -a _${SPECIES}.repeats.bed -b _${SPECIES}.genes.bed >\
	_${SPECIES}.repeats.curated.bed


## 6) sort and convert to 0-based BED
sort -k1,1 -k2,2n _${SPECIES}.repeats.curated.bed | \
	perl -lane '$F[1]-=1; print join("\t",@F)' >\
	_${SPECIES}.repeats.sorted.bed

## 7) download and uncompress genomic sequence 
FASTA="*${SPECIES^}*.dna.toplevel.fa.gz"
URL="${FTPSERVER}/${DIV}/current/fasta/${SPECIES}/dna/${FASTA}"
echo "# downloading $URL"
wget -c $URL -O- | gunzip > _${SPECIES}.dna

## 8) extract repeat sequences 
bedtools getfasta -name -fi _${SPECIES}.dna -bed _${SPECIES}.repeats.sorted.bed >\
	_${SPECIES}.repeats.dna

## 9) eliminate degenerate (MAXDEGENPERC) 
cat _${SPECIES}.repeats.dna | \
	perl -slne 'if(/^(>.*)/){$h=$1} else {$fa{$h}.=$_} END{ foreach $h (keys(%fa)){ $l=length($fa{$h}); $dg=($fa{$h}=~tr/Nn//); print "$h\n$fa{$h}" if(100*$dg/$l<=$maxdeg) }}' \
	-- -maxdeg=$MAXDEGENPERC > _${SPECIES}.repeats.nondeg.dna

# 10) eliminate short and redundant sequences 
cd-hit-est -c 0.99 -l $MINLEN -i _${SPECIES}.repeats.nondeg.dna \
	-o ${SPECIES}.${EGRELEASE}.repeats.nr.dna

# 11) clean temp file


exit 0
