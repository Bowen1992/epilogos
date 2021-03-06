#! /bin/bash

# set -e -o pipefail

usage() {
    echo -e "Usage:  $0 queueName fileOfPerChromFilenames numStates metric outdir groupSpec [group2spec]"
    echo -e "where"
    echo -e "* queueName is the name of the SLURM-managed resource on which the jobs will run"
    echo -e "* fileOfPerChromFilenames contains one input filename per line (including path if needed);"
    echo -e "  each chrom-specific infile consists of tab-delimited coordinates (chrom, start, stop)"
    echo -e "  and states observed at those loci for epigenome 1 (in column 4), epigenome 2 (in column 5), etc."
    echo -e "  States are integers with values 1, 2, ..., numStates."
    echo -e "* numStates is the number of possible states"
    echo -e "* metric is either 1 (S1), 2 (S2), or 3 (S3)"
    echo -e "* groupSpec specifies epigenomes to use in the analysis;"
    echo -e "  these are epigenome numbers corresponding to the order in which they appear in the input files"
    echo -e "  (e.g. 1, 2, 3 for the first three epigenomes, whose states are in columns 4, 5, 6)."
    echo -e "  groupSpec is a comma- and/or hyphen-delimited list (e.g. \"1,3,6-10,12,13\")."
    echo -e "  By default, the analysis will be performed on a single group of epigenomes."
    echo -e "* If an optional specification for a second group of epigenomes is provided as the last argument (group2spec),"
    echo -e "  then the analysis will be a comparison between the two groups of epigenomes."
    echo -e "* outdir will be created if necessary, and all results files will be written there."
    exit 2
}
    
if [[ $# != 6 ]] && [[ $# != 7 ]]; then # invalid number of arguments
    usage
fi    

queueName=$1
fileOfFilenames=$2
numStates=$3
metric=$4
outdir=$5
groupAspec=$6
groupBspec=""
if [ "$7" != "" ]; then
    groupBspec=$7
fi

# metric directs the programs to use S1, S2, or S3
if [ "$metric" != "1" ] && [ "$metric" != "2" ] && [ "$metric" != "3" ]; then
    echo -e "Error:  Invalid \"metric\" (\"$metric\") received."
    usage
fi
S1=0
S2=0
S3=0
if [ "$metric" == "1" ]; then
    S1=1
    SCORE_COLUMN=7
elif [ "$metric" == "2" ]; then
    S2=1
    SCORE_COLUMN=10
elif [ "$metric" == "3" ]; then
    S3=1
    SCORE_COLUMN=10
else
    echo -e "Error:  Mode of operation \"$metric\" not implemented."
    exit 2
fi
STATE_COLUMN=4
    
if [ ! -s "$fileOfFilenames" ]; then
    echo -e "Error:  File \"$fileOfFilenames\" was not found, or it is empty."
    exit 2
fi

EXE1=`which computeEpilogosPart1_perChrom`
EXE2=`which computeEpilogosPart2_perChrom`
EXE3=`which computeEpilogosPart3_perChrom`

if [ ! -x "$EXE1" ]; then
    echo -e "Error:  Required executable \"$EXE1\" not found, or it is not executable."
    echo -e "Instructions for building this file and making it accessible are in the file README.md."
    exit 2
fi
if [ ! -x "$EXE2" ]; then
    echo -e "Error:  Required executable \"$EXE2\" not found, or it is not executable."
    echo -e "Instructions for building this file and making it accessible are in the file README.md."
    exit 2
fi
if [ ! -x "$EXE3" ]; then
    echo -e "Error:  Required executable \"$EXE3\" not found, or it is not executable."
    echo -e "Instructions for building this file and making it accessible are in the file README.md."
    exit 2
fi

numStatesIsValid=`echo $numStates | awk '{if($0<1){print "0"; exit 1}else{print}}' | sed 's/[0-9]//g' | awk '{if(""==$0){print "1"}else{print "0"}}'`
if [ "0" == "$numStatesIsValid" ]; then
    echo -e "Error:  Invalid number of states specified (\"$numStates\").  This must be a positive integer."
    usage
fi

# Validate the group specifications
$EXE1 $groupAspec $groupBspec > /dev/null
if [ "$?" != 0 ]; then
    if [ "$groupBspec" == "" ]; then
	echo -e "Error in the group specification (\"$groupAspec\")."
    else
	echo -e "Error in one or both group specifications (\"$groupAspec\" and \"$groupBspec\")."
    fi
    usage
fi

groupBsize="0"
groupAsize=`$EXE1 $groupAspec`
if [ "$groupBspec" != "" ]; then
    groupBsize=`$EXE1 $groupBspec`
fi

mkdir -p $outdir

# If all 3 final output files already exist, assume this is a re-run that isn't necessary.
if [ -s ${outdir}/observations.starch ] && [ -s ${outdir}/scores.txt.gz ] && [ -s ${outdir}/exemplarRegions.txt ]; then
    echo -e "All 3 final output files already exist and are non-empty:"
    echo -e "\t${outdir}/observations.starch"
    echo -e "\t${outdir}/scores.txt.gz"
    echo -e "\t${outdir}/exemplarRegions.txt"
    echo -e "Exiting, under the assumption that these files should not be recreated from scratch."
    echo -e "To recreate these files, move/rename them before running this program."
    exit 0
fi

# Get a quick estimate of the total number of sites genome-wide.
# This will be used to estimate memory needs for later parts of the computation.
tempVar=""
linenum=0
while read line
do
    ((linenum++))
    file=$line
    if [ ! -s $file ]; then
	echo -e "Error:  File \"$file\", on line $linenum of $fileOfFilenames, was not found, or it is empty."
	exit 2
    fi
    bytes=`ls -l $file | awk '{print $5}'`
    maxNumEpis=`head -n 1 $file | cut -f4- | awk '{print NF}'`
    approxLineCount=`echo $bytes | awk -v n=$maxNumEpis '{print int($1/(n*3))}'`
    tempVar=${tempVar}":"${approxLineCount}
done <<< "$(cat $fileOfFilenames)" # see note above regarding this syntax
approxTotalNumSites=`echo $tempVar | sed 's/^://' | tr ':' '\n' | awk 'BEGIN{approxTotalLines=0}{approxTotalLines+=$1}END{print approxTotalLines}'`

# ----------------------------------
# echo -e "Executing \"part 1a\"..."
# ----------------------------------

outfileRand="" # used only if 2 groups of epigenomes are being compared
outfileQB=""   # used only if 2 groups of epigenomes are being compared
PfilenameString=""
randFilenameString=""
dependencies="afterok" # SLURM syntax
# Important:
# Need to code this as follows (i.e., "while read line do ... done <<< input"
# instead of "input | while read line do ... done"),
# because otherwise the body of the loop gets executed in a subshell (due to the '|'),
# and the updates to variable "dependencies" aren't passed back to the parent shell
# (i.e., they're lost after the "done" statement).
while read line
do
    file=$line
    chr=`head -n 1 $file | cut -f1`
    outfileNsites=${outdir}/${chr}_numSites.txt
    if [ $S1 == 1 ]; then
	PfilenameString="_P1numerators.txt"
	outfileQ=${outdir}/${chr}_Q1numerators.txt
	if [ "$groupBspec" != "" ]; then
	    randFilenameString="_randP1numerators.txt"
	    outfileRand=${outdir}/${chr}${randFilenameString}
	    outfileQ=${outdir}/${chr}_Q1Anumerators.txt
	    outfileQB=${outdir}/${chr}_Q1Bnumerators.txt
	fi
    elif [ $S2 == 1 ]; then
	PfilenameString="_P2numerators.txt"
	outfileQ=${outdir}/${chr}_Q2numerators.txt
	if [ "$groupBspec" != "" ]; then
	    randFilenameString="_randP2numerators.txt"
	    outfileRand=${outdir}/${chr}${randFilenameString}
	    outfileQ=${outdir}/${chr}_Q2Anumerators.txt
	    outfileQB=${outdir}/${chr}_Q2Bnumerators.txt
	fi
    else
	PfilenameString="_statePairs.txt"
	outfileQ=${outdir}/${chr}_Q3Tallies.txt
	if [ "$groupBspec" != "" ]; then
	    randFilenameString="_randomizedStatePairs.txt"
	    outfileRand=${outdir}/${chr}${randFilenameString}	    
	    outfileQ=${outdir}/${chr}_Q3Atallies.txt
	    outfileQB=${outdir}/${chr}_Q3Btallies.txt
	fi
    fi
    outfileP=${outdir}/${chr}${PfilenameString}

    # This could be a new run, or a re-run if the cluster or electricity was disabled in the middle of a previous run.
    processThisChromosome="YES"

    if [ -s ${outdir}/observations.starch ]; then
	if [ -s ${outdir}/scores.txt.gz ] || [ -s ${outdir}/${chr}_scores.txt ]; then
	    if [[ "$groupBspec" == "" || ("$groupBspec" != "" && ( -s $outfileRand || -s ${outdir}/allNullsGenomewide.txt )) ]]; then
		processThisChromosome="NO"
	    fi
	fi
    else
	if [[ -s ${outdir}/${chr}_observed.txt || -s ${outdir}/${chr}_observed.bed || -s ${outdir}/${chr}_observed_withPvals.bed ]]; then
	    if [ -s ${outdir}/scores.txt.gz ] || [ -s ${outdir}/${chr}_scores.txt ]; then
		if [[ "$groupBspec" == "" || ("$groupBspec" != "" && ( -s $outfileRand || -s ${outdir}/allNullsGenomewide.txt )) ]]; then
		    processThisChromosome="NO"
		fi
	    fi
	fi
    fi

    jobName="p1a_$chr"
    offset=4000      # estimated empirically
    coefficient=0.03 # estimated empirically
    maxNumEpigenomes=`head -n 1 $file | cut -f4- | awk '{print NF}'`
    memSize=`echo $maxNumEpigenomes | awk -v c=$offset -v gA=$groupAsize -v gB=$groupBsize '{print c + $1 + gA + gB}'`
    if [ $S1 == 1 ]; then
	memSize=`echo $memSize | awk -v ns=$numStates -v gB=$groupBsize '{kbOut = $1 + 2*ns; if(gB!=0){kbOut += 4*ns} print kbOut}'`
    elif [ $S2 == 1 ]; then
	memSize=`echo $memSize | awk -v ns=$numStates -v gB=$groupBsize '{kbOut = $1 + ns*(ns+1); if(gB!=0){kbOut += 2*ns*(ns+1)} print kbOut}'`
    else
	memSize=`echo $memSize | awk -v ns=$numStates -v gA=$groupAsize -v gB=$groupBsize -v a=$coefficient '{print $1 + a*(ns*ns + 0.5*ns*ns*(gA*(gA-1) + gB*(gB-1)))}'`
    fi
    memSize=`echo $memSize | awk '{print int($1/1000. + 0.5)"M"}'`
    if [ "YES" == $processThisChromosome ]; then
	thisJobID=$(sbatch --parsable --partition=$queueName --job-name=$jobName --output=${outdir}/${jobName}.o%j --error=${outdir}/${jobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
        $EXE1 $file $metric $numStates $outfileP $outfileQ $outfileNsites $groupAspec $groupBspec $outfileRand $outfileQB
        if [ \$? != 0 ]; then
           exit 2
        fi
EOF
	)
	dependencies="${dependencies}:${thisJobID}"
    fi

done <<< "$(cat $fileOfFilenames)" # see note above regarding this syntax

# ----------------------------------
# echo -e "Executing \"part 1b\"..."
# ----------------------------------

# Add up the Q1 (or Q2 or Q3) tallies to get the genome-wide Q1 (or Q2 or Q3) matrices,
# or to get the Q1A and Q1B (or Q2A and Q2B, or Q3A and Q3B) matrices
# if two groups of epigenomes are being compared.

PID=$$
QQjobName=QQ_1b_${PID}
outfileQB=""
QBfilenameString=""
if [ $S1 == 1 ]; then
    outfileQ=${outdir}/Q1.txt
    QfilenameString="_Q1numerators.txt"
    if [ "$groupBspec" != "" ]; then
	outfileQ=${outdir}/Q1A.txt
	outfileQB=${outdir}/Q1B.txt
	QfilenameString="_Q1Anumerators.txt"
	QBfilenameString="_Q1Bnumerators.txt"
    fi
elif [ $S2 == 1 ]; then
    outfileQ=${outdir}/Q2.txt
    QfilenameString="_Q2numerators.txt"
    if [ "$groupBspec" != "" ]; then
	outfileQ=${outdir}/Q2A.txt
	outfileQB=${outdir}/Q2B.txt
	QfilenameString="_Q2Anumerators.txt"
	QBfilenameString="_Q2Bnumerators.txt"
    fi
else
    outfileQ=${outdir}/Q3.txt
    QfilenameString="_Q3Tallies.txt"
    if [ "$groupBspec" != "" ]; then
	outfileQ=${outdir}/Q3A.txt
	outfileQB=${outdir}/Q3B.txt
	QfilenameString="_Q3Atallies.txt"
	QBfilenameString="_Q3Btallies.txt"
    fi
fi

tempfile=${outdir}/tempfile_Q_${PID}.txt
TEMP1=${outdir}/tempfile1_Q_${PID}.txt
TEMP2=${outdir}/tempfile2_Q_${PID}.txt
if [ $dependencies == "afterok" ]; then
    dependencyString=""
else
    dependencyString="--dependency="$dependencies
fi

dependencyString2=""
if [[ ! -s ${outdir}/observations.starch && ! -s ${outdir}/scores.txt.gz && (! -s $outfileQ || ("$groupBspec" != "" && ! -s $outfileQB)) ]]; then
    if [[ $dependencyString == "" &&
		(`ls -1 ${outdir}/chr*${QfilenameString} 2> /dev/null | wc -l` == "0" ||
			`ls -1Sl ${outdir}/chr*${QfilenameString} 2> /dev/null | head -n 1 | awk '{print $5}'` == "0") ]]; then
	echo -en "Error:  Attempted to construct file "
	if [ ! -s $outfileQ ]; then
	    echo -en $outfileQ
	else
	    echo -en $outfileQB
	fi
	echo -e ", but the necessary file(s) (${outdir}/chr*${QfilenameString}) were not found, or are empty."
	echo -e "Try removing intermediate files and re-running."
	exit 2
    fi
    if [ $S3 == 1 ]; then
	memSize=`echo 2 | awk -v gA=$groupAsize -v gB=$groupBsize -v ns=$numStates '{gmax=gA;if(gB>gA){gmax=gB}print int($1 + 3*(ns*ns*gmax*(gmax-1)/2)/1000000 + 0.5)"M"}'`
	# the factor of 3 provides a bit of extra room for safety
    else
	memSize="2M" # more than enough
    fi
    
    QQjobID=$(sbatch --parsable --partition=$queueName $dependencyString --job-name=$QQjobName --output=${outdir}/${QQjobName}.o%j --error=${outdir}/${QQjobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
firstFile=\`ls -1 ${outdir}/chr*${QfilenameString} | head -n 1\`
if [ ! -s \$firstFile ]; then
   echo -e "Error:  File "\$firstFile" is empty."
   exit 2
fi
numRows=\`wc -l < \$firstFile\`
awk '{print NF}' \$firstFile | sort -n | uniq > $tempfile
if [ \`wc -l < $tempfile\` != "1" ]; then
   echo -e "Error:  File "\$firstFile" has at least two rows with different numbers of columns."
   exit 2
fi
numCols=\`cat $tempfile\`

cp \$firstFile $TEMP1
for file in \`ls -1 ${outdir}/chr*${QfilenameString} | tail -n +2\`
do
   if [ ! -s \$file ]; then
      echo -e "Error:  File "\$file" is empty."
      exit 2
   fi
   thisNumRows=\`wc -l < \$file\`
   awk '{print NF}' \$file | sort -n | uniq > $tempfile
   if [ \`wc -l < $tempfile\` != "1" ]; then
      echo -e "Error:  File "\$file" has at least two rows with different numbers of columns."
      exit 2
   fi
   thisNumCols=\`cat $tempfile\`
   if [ \$thisNumRows != \$numRows ]; then
      echo -en "Error:  Files "\$firstFile" and "\$file" have different numbers of rows ("
      echo \$numRows" and "\$thisNumRows")."
      exit 2
   fi
   if [ \$thisNumCols != \$numCols ]; then
      echo -en "Error:  Files "\$firstFile" and "\$file" have different numbers of columns ("
      echo \$numCols" and "\$thisNumCols")."
      exit 2
   fi

   paste $TEMP1 \$file \
      | awk -v nCols=\$numCols '{printf("%d", \$1 + \$(nCols + 1)); \
                                 for (i=2; i<= nCols; i++){ \
                                    printf("\t%d", \$i + \$(nCols + i)); \
                                 } \
                                 printf("\n"); \
                                }' \
      > $TEMP2
   mv $TEMP2 $TEMP1
done
cp $TEMP1 $outfileQ
rm -f ${outdir}/chr*${QfilenameString}

if [ "$groupBspec" != "" ]; then
   firstFile=\`ls -1 ${outdir}/chr*${QBfilenameString} | head -n 1\`
   if [ ! -s \$firstFile ]; then
      echo -e "Error:  File "\$firstFile" is empty."
      exit 2
   fi
   numRows=\`wc -l < \$firstFile\`
   awk '{print NF}' \$firstFile | sort -n | uniq > $tempfile
   if [ \`wc -l < $tempfile\` != "1" ]; then
      echo -e "Error:  File "\$firstFile" has at least two rows with different numbers of columns."
      exit 2
   fi
   numCols=\`cat $tempfile\`

   cp \$firstFile $TEMP1
   for file in \`ls -1 ${outdir}/chr*${QBfilenameString} | tail -n +2\`
   do
      if [ ! -s \$file ]; then
         echo -e "Error:  File "\$file" is empty."
         exit 2
      fi
      thisNumRows=\`wc -l < \$file\`
      awk '{print NF}' \$file | sort -n | uniq > $tempfile
      if [ \`wc -l < $tempfile\` != "1" ]; then
         echo -e "Error:  File "\$file" has at least two rows with different numbers of columns."
         exit 2
      fi
      thisNumCols=\`cat $tempfile\`
      if [ \$thisNumRows != \$numRows ]; then
         echo -en "Error:  Files "\$firstFile" and "\$file" have different numbers of rows ("
         echo \$numRows" and "\$thisNumRows")."
         exit 2
      fi
      if [ \$thisNumCols != \$numCols ]; then
         echo -en "Error:  Files "\$firstFile" and "\$file" have different numbers of columns ("
         echo \$numCols" and "\$thisNumCols")."
         exit 2
      fi

      paste $TEMP1 \$file \
         | awk -v nCols=\$numCols '{printf("%d", \$1 + \$(nCols + 1)); \
                                    for (i=2; i<= nCols; i++){ \
                                       printf("\t%d", \$i + \$(nCols + i)); \
                                    } \
                                    printf("\n"); \
                                   }' \
         > $TEMP2
      mv $TEMP2 $TEMP1
   done
   cp $TEMP1 $outfileQB
   rm -f ${outdir}/chr*${QBfilenameString}
fi

rm -f $tempfile $TEMP1 $TEMP2

EOF
	   )
    dependencyString2="--dependency=afterok:"${QQjobID}
fi

# ----------------------------------
# echo -e "Executing \"part 1c\"..."
# ----------------------------------

totalNumSitesFile=${outdir}/totalNumSites.txt
totalSitesJobName=QQ_1c_${PID}
memSize="5M" # more than enough; these are byte-size files.
if [ ! -s $totalNumSitesFile ]; then
    if [[ ($dependencyString == "" && $dependencyString2 == "") &&
	      (`ls -1 ${outdir}/chr*_numSites.txt 2> /dev/null | wc -l` == "0" || `ls -1Sl ${outdir}/chr*_numSites.txt 2> /dev/null | head -n 1 | awk '{print $5}'` == "0") ]]; then
	echo -e "Error:  $totalNumSitesFile is missing or empty, and the files needed to create it (${outdir}/chr*_numSites.txt) are also missing or empty."
	echo -e "Try removing intermediate files and re-running."
	exit 2
    fi
    totalSitesJobID=$(sbatch --parsable --partition=$queueName $dependencyString2 --job-name=$totalSitesJobName --output=${outdir}/${totalSitesJobName}.o%j --error=${outdir}/${totalSitesJobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
   cat ${outdir}/chr*_numSites.txt \
      | awk 'BEGIN{sum=0}{sum += \$0}END{print sum}' \
      > $totalNumSitesFile
   rm ${outdir}/chr*_numSites.txt
EOF
	       )
    dependencyString2="--dependency=afterok:"${totalSitesJobID}
fi

# ----------------------------------
# echo -e "Executing \"part 2a\"..."
# ----------------------------------

dependencies="afterok" # SLURM syntax
# Important:
# Need to code this as follows (i.e., "while read line do ... done <<< input"
# instead of "input | while read line do ... done"),
# because otherwise the body of the loop gets executed in a subshell (due to the '|'),
# and the updates to variable "dependencies" aren't passed back to the parent shell
# (i.e., they're lost after the "done" statement).
while read line
do
    file=$line
    chr=`head -n 1 $file | cut -f1`
    infile=${outdir}/${chr}${PfilenameString}
    infileQ=$outfileQ
    infileQB=$outfileQB # empty ("") if only one group of epigenomes was specified
    outfileObserved=${outdir}/${chr}_observed.txt
    outfileScores=${outdir}/${chr}_scores.txt
    outfileNulls=""
    if [ "$groupBspec" != "" ]; then
	outfileNulls=${outdir}/${chr}_nulls.txt
	outfileObsFromPart3=`echo $outfileObserved | sed 's/\.txt$/_withPvals.bed/'`
    else
	outfileObsFromPart3=`echo $outfileObserved | sed 's/txt$/bed/'`
    fi
    jobName="p2_$chr"
    offset=4000     # estimated empirically
    coefficient=0.3 # estimated empirically
    memSize=`echo $numStates | awk -v c=$offset '{print c + $1}'`
    if [ $S1 == 1 ]; then
	memSize=`echo $memSize | awk -v ns=$numStates -v gA=$groupAsize -v gB=$groupBsize '{gmax=gA; if(gB>gA){gmax=gB} \
           kbOut = $1 + 2*ns + gmax; if(gB!=0){kbOut += 2*ns} print kbOut}'`
    elif [ $S2 == 1 ]; then
	memSize=`echo $memSize | awk -v ns=$numStates -v gA=$groupAsize -v gB=$groupBsize '{gmax=gA; if(gB>gA){gmax=gB} \
           kbOut = $1 + 3*ns*(ns+1)/2 + gmax*(gmax-1)/2; if(gB!=0){kbOut += ns*(ns+1)} print kbOut}'`
    else
	memSize=`echo $memSize | awk -v a=$coefficient -v ns=$numStates -v gA=$groupAsize -v gB=$groupBsize '{gmax=gA; gmin=gB; if(gB>gA){gmax=gB; gmin=gA} \
           kbOut = $1 + a*(ns*ns + (1 + 4*ns*ns)*gmax*(gmax-1)/2); if(gB!=0){kbOut += a*(ns*ns*gmin*(gmin-1))} print kbOut}'`
    fi
    memSize=`echo $memSize | awk '{print int($1/1000. + 0.5)"M"}'`    
    
    if [[ ( ! -s $outfileObserved && ! -s $outfileObsFromPart3 && ! -s ${outdir}/observations.starch ) || ( ! -s $outfileScores && ! -s ${outdir}/scores.txt.gz ) ]]; then
	thisJobID=$(sbatch --parsable --partition=$queueName $dependencyString2 --job-name=$jobName --output=${outdir}/${jobName}.o%j --error=${outdir}/${jobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
   totalNumSites=\`cat $totalNumSitesFile\`
   $EXE2 $infile $metric \$totalNumSites $infileQ $outfileObserved $outfileScores $chr $infileQB
   if [ \$? != 0 ]; then
      exit 2
   fi
EOF
		 )
    dependencies="${dependencies}:${thisJobID}"
    fi
    if [ "$groupBspec" != "" ] && [ ! -s $outfileNulls ]; then
	infile=${outdir}/${chr}${randFilenameString}
	jobName="p2r_$chr"
	thisJobID=$(sbatch --parsable --partition=$queueName $dependencyString2 --job-name=$jobName --output=${outdir}/${jobName}.o%j --error=${outdir}/${jobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
   totalNumSites=\`cat $totalNumSitesFile\`
   # The smaller number of arguments in the following call informs $EXE2 that it should only write the metric to $outfileNulls, with no additional info.
   $EXE2 $infile $metric \$totalNumSites $infileQ $infileQB $outfileNulls
   if [ \$? != 0 ]; then
      exit 2
   else # clean up
      rm -f $infile
   fi
EOF
		 )
    dependencies="${dependencies}:${thisJobID}"
    fi
	
done <<< "$(cat $fileOfFilenames)" # see note above regarding this syntax

# ----------------------------------
# echo -e "Executing \"part 2b\"..."
# ----------------------------------

memSize=`echo $approxTotalNumSites | awk -v ns=$numStates -v safeApproxMeanBytesPerField=14 '{print int($1*(4 + ns)*safeApproxMeanBytesPerField/1000000. + 0.5)"M"}'`
part2bJobName=p2b_${PID}
if [ $dependencies == "afterok" ]; then
    dependencyString=""
else
    dependencyString="--dependency="$dependencies
fi
dependencyString2=""

if [[ ! -s ${outdir}/scores.txt.gz || ( "$groupBspec" != "" && ! -s ${outdir}/allNullsGenomewide.txt ) ]]; then
    part2bJobID=$(sbatch --parsable --partition=$queueName $dependencyString --job-name=$part2bJobName --output=${outdir}/${part2bJobName}.o%j --error=${outdir}/${part2bJobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
   module load htslib
   cat ${outdir}/*_scores.txt \
      | sort -k1b,1 -s \
      | bgzip \
      > ${outdir}/scores.txt.gz
   if [ \$? != 0 ]; then
      echo -e "An error occurred while attempting to combine and compress the per-chromosome score files."
      exit 2
   fi
   rm -f ${outdir}/*_scores.txt
          
   if [ "$groupBspec" != "" ] && [ ! -s ${outdir}/allNullsGenomewide.txt ]; then
      cat ${outdir}/*_nulls.txt > ${outdir}/allNullsGenomewide.txt
      if [ \$? != 0 ]; then
         echo -e "An error occurred while attempting to concatenate the per-chromosome null values."
         exit 2
      fi
      rm -f ${outdir}/*_nulls.txt
   fi
   # Clean up some files
   rm -f ${outdir}/*${PfilenameString}
EOF
    )
    dependencyString2="--dependency=afterok:"${part2bJobID}
fi

# ----------------------------------
# echo -e "Executing \"part 3\"..."
# ----------------------------------

dependencies="afterok"

while read line
do
    origFile=$line
    chr=`head -n 1 $origFile | cut -f1`
    begPos=`head -n 1 $origFile | cut -f2`
    endPos=`head -n 1 $origFile | cut -f3`
    infile=${chr}_observed.txt
    if [ "$groupBspec" != "" ]; then
	outfile=`echo $infile | sed 's/\.txt$/_withPvals.bed/'`
	memSize=`echo $approxTotalNumSites | awk -v safeApproxMeanBytesPerField=8 '{print int(0.5*$1*safeApproxMeanBytesPerField/1000000)"M"}'`
    else
	outfile=`echo $infile | sed 's/txt$/bed/'`
	memSize="2M" # all we'll be doing is renaming a file	
    fi
    outfile=${outdir}/${outfile}
    infile=${outdir}/${infile}
    jobName="p3_$chr"
    if [[ ! -s $outfile &&  ! -s ${outdir}/observations.starch ]]; then
	thisJobID=$(sbatch --parsable --partition=$queueName $dependencyString2 --job-name=$jobName --output=${outdir}/${jobName}.o%j --error=${outdir}/${jobName}.e%j --mem=$memSize <<EOF
#! /bin/bash
   if [ -s ${outdir}/allNullsGenomewide.txt ]; then
      $EXE3 $infile ${outdir}/allNullsGenomewide.txt $outfile
      if [ \$? == 0 ]; then
         rm -f $infile
      fi
   else
      mv $infile $outfile
   fi
EOF
	)
	dependencies="${dependencies}:${thisJobID}"
    fi
done <<< "$(cat $fileOfFilenames)"

# --------------------------------------
# echo -e "Collating and cleaning up..."
# --------------------------------------

if [ $dependencies == "afterok" ]; then
    dependencyString=""
else
    dependencyString="--dependency=$dependencies"
fi
finalJobName=finalStep
memSize="5M" # this should be sufficient, due to how bedops/starch/unstarch and awk process input

finalJobID=$(sbatch --parsable --partition=$queueName $dependencyString --job-name=$finalJobName --output=${outdir}/${finalJobName}.o%j --error=${outdir}/${finalJobName}.e%j --mem=$memSizeFinal <<EOF
#! /bin/bash
   module load bedops
   if [ -s ${outdir}/allNullsGenomewide.txt ] && [ \`ls -1 ${outdir}/*_observed_withPvals.bed | wc -l\` != "0" ]; then
      rm -f ${outdir}/allNullsGenomewide.txt
   fi
   if [ ! -s ${outdir}/observations.starch ]; then
      bedops -u ${outdir}/*_observed*.bed | starch - > ${outdir}/observations.starch
      if [ \$? == 0 ]; then
         rm -f ${outdir}/*_observed*.bed
      else
         echo -e "An error occurred while trying to execute \"bedops -u ${outdir}/*_observed*.bed | starch - > ${outdir}/observations.starch\"."
         exit 2
      fi
   fi
   rm -f $outfileQ $outfileQB

   unstarch ${outdir}/observations.starch \
	 | awk -v stateCol=$STATE_COLUMN -v scoreCol=$SCORE_COLUMN 'BEGIN {OFS="\t"; chrom=""; state=""; bestScore=""; line=""} \
           { \
              if (\$(stateCol) != state || \$1 != chrom) { \
                 if (state != "") { \
                    print line; \
                 } \
                 chrom = \$1; \
                 state = \$(stateCol); \
                 bestScore = \$(scoreCol); \
                 line = \$0; \
              } else { \
                 if (\$(scoreCol) >= bestScore) { \
                    bestScore = \$(scoreCol); \
                    line = \$0; \
                 } \
              } \
           } END { \
                      if (line != "") { \
                         print line; \
                      } \
                 }' \
	 | sort -gr -k${SCORE_COLUMN},${SCORE_COLUMN} \
	 > ${outdir}/exemplarRegions.txt
EOF
	   )

exit 0
