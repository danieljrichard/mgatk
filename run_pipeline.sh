#####
##I deconstructed the MGATK pipeline a bit, and now want to formalize the steps to take if a complete run is wanted
##July 17th 2024
#####

##This requires that the SNAKEMAKE files have been edited, both the original tenx file, and there's another 'CONT' tenx file that I added.
##also, you'll need a modified cli.py script, as this is modified to facilitate running.
##
##THIS runs START TO FINISH.
#
#./test.sh C1_test1 C1_test_RAW_mgatk_mk5
#./run_pipeline.sh C2_test_RAW C2_test_RAW_mgatk

SAMPLE=$1
OUTDIR=$2

echo "mgatk tenx  -g mm10 -i possorted_bam.bam -n $SAMPLE -o $OUTDIR -c 24 -bt CB -b barcodes.tsv --keep-temp-files --keep-qc-bams"
mgatk tenx  -g mm10 -i possorted_bam.bam -n $SAMPLE -o $OUTDIR -c 24 -bt CB -b barcodes.tsv --keep-temp-files --keep-qc-bams

##Make directories.
OUT1="_FOLDER_MAKE_COMMANDS.txt"
chmod +x $SAMPLE$OUT1
echo "./$SAMPLE$OUT1"
./$SAMPLE$OUT1

##Now run the commands

OUT2="_COMMAND_SET.txt"
ls $2/temp/*_set_BASH.txt | awk '{print "bash "$1}' > $SAMPLE$OUT2
echo "parallel -j 10 < $SAMPLE$OUT2"
parallel -j 10 < $SAMPLE$OUT2

##once that finishes running, 

OUT3="_pool_commands.txt"
ls $2/temp/*POOL*.txt > $SAMPLE$OUT3
echo "cat $SAMPLE$OUT3 | xargs -i bash {}"
cat $SAMPLE$OUT3 | xargs -i bash {}

echo "mgatk CONT  -g mm10 -i possorted_bam.bam -n $SAMPLE -o $OUTDIR -c 24 -bt CB -b barcodes.tsv --keep-temp-files --keep-qc-bams"
mgatk CONT  -g mm10 -i possorted_bam.bam -n $SAMPLE -o $OUTDIR -c 24 -bt CB -b barcodes.tsv --keep-temp-files --keep-qc-bams

echo 'done'
