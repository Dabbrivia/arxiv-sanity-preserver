#!/bin/bash
# vi: tabstop=2 expandtab shiftwidth=2 softtabstop=2
# add to crontab -e 
# 16 04 * * * . /home/ubuntu/.profile; /home/ubuntu/arxiv-sanity-preserver/daily_update.sh 2>/data/daily_update.log
# the single dot is the command to source profile
export HOMEDIR="/home/ubuntu"; # python virtualenv environment
source "$HOMEDIR/env/bin/activate"; # python virtualenv environment
export WORKDIR="/data/asps"
export PDFDIR="/data/pdf"
export TXTDIR="/data/txt"
export JPGDIR="/data/jpg"
export SOURCEROOT="/home/ubuntu/arxiv-sanity-preserver/"
# array of dirnames for all fields of arXiv we want and their handles
unset -v FIELDS
declare -A FIELDS
FIELDS[arxiv-sanity-preserver]='physics:cond-mat'
FIELDS[cond-mat]='physics:cond-mat'
FIELDS[cs]='cs'

# prepare to download pdfs for this month
mkdir -p "$PDFDIR/$(date +%y%m)"

# the exclamation mark makes sure we list indexes (dirnames)
for FIELD in "${!FIELDS[@]}";
	do
    echo "Processing $FIELD"
		if ! [ -d "$WORKDIR/$FIELD" ]; then 
			echo "Setting up directory $WORKDIR/$FIELD for field ${FIELDS[$FIELD]}"
			mkdir -p "$WORKDIR/$FIELD/data"; 
			mkdir -p "$WORKDIR/$FIELD/tmp"
			ln -s "$PDFDIR" "$WORKDIR/$FIELD/data/pdf"; 
			ln -s "$TXTDIR" "$WORKDIR/$FIELD/data/txt"; 
			#ln -s "$JPGDIR" "$WORKDIR/$FIELD/static/thumbs" 
			cp "$SOURCEROOT"{OAI_seed_db,parse_OAI_XML,download_pdfs,utils}.py "$WORKDIR/$FIELD/";
			cp "$SOURCEROOT"{buildsvm,make_cache,serve,twitter_daemon}.py "$WORKDIR/$FIELD/";
			cp "$SOURCEROOT"{pdf_failed_conversion_to.jpg,ui.jpeg,schema.sql,run_sever.sh} "$WORKDIR/$FIELD/";
			cp -r /home/ubuntu/arxiv-sanity-preserver/{static,templates}/ "$WORKDIR/$FIELD/";
			cd "$WORKDIR/$FIELD" && sqlite3 as.db < schema.sql ;
			# TODO cp and edit secret_key.txt, twitter_txt
		fi;
		echo "Downloading Papers into directory $FIELD for arXiv Field ${FIELDS[$FIELD]}";
		cd "$WORKDIR/$FIELD"; python "$WORKDIR/$FIELD/OAI_seed_db.py" \
			--from-date '2020-02-21' --set "${FIELDS[$FIELD]}";  # how to set from-date?
		python "$WORKDIR/$FIELD/download_pdfs.py";
	done;	

# this is common for all fields and should be run only once
#cd /home/ubuntu/arxiv-sanity-preserver/;
#python /home/ubuntu/arxiv-sanity-preserver/download_pdfs.py

# For PDF to txt conversion 
# fix imagemagic policy issue preventing creation of the thumbnails
# https://stackoverflow.com/a/52863413
# MANUALLY add 
# <policy domain="module" rights="read|write" pattern="{PS,PDF,XPS}" /> 
# to /etc/ImageMagick-6/policy.xml
# on webserver where archive-sanity-preserver is installed.

function create_txt_and_thumbs {
pdfpath=/data/pdf #/data/pdf/2002/2002.01868.pdf
filename="$1"
#echo "$filename"
shortpath=${1#/*pdf} #/2002/2002.01868.dir
dir_fileroot=${shortpath%.pdf} # /2002/2002.01868

[ ! -e /data/txt"$dir_fileroot".txt ] && ( (timeout 120 pdftotext $filename \
/data/txt"$dir_fileroot".txt) || touch /data/txt"$dir_fileroot".txt);

[ ! -e /data/jpg"$dir_fileroot".jpg ] && (timeout 120 convert $filename[0-7] \
-thumbnail x156 "${filename%.*}".png; \
montage -mode concatenate -quality 80 \
-tile x1 "${filename%.*}"*.png /data/jpg"$dir_fileroot".jpg \
|| ln -s /home/ubuntu/arxiv-sanity-preserver/pdf_failed_conversion_to.jpg \
/data/jpg"$dir_fileroot".jpg; \
rm "${filename%.*}"*.png );

}
export -f create_txt_and_thumbs

cd /data/pdf; find ./ -type d -exec sh -c 'mkdir -p /data/txt/${1#"./"}; \
mkdir -p /data/jpg/${1#"./"}; ' sh {} \;

time find /data/pdf/ -type f -name "*.pdf"|parallel create_txt_and_thumbs {}

/snap/bin/aws s3 sync /data/txt s3://abbrivia.private-arxiv/jpg_txt/ \
	--exclude "*" --include "*.txt" --include "*.jpg" &

#/snap/bin/aws s3 sync s3://abbrivia.private-arxiv/jpg_txt /data/jpg/  \
#	--exclude "*" --include "*.jpg"
#/snap/bin/aws s3 sync s3://abbrivia.private-arxiv/jpg_txt /data/txt/  \
#	--exclude "*" --include "*.txt"

export WORKER_ID=i-0b8a8a78e1f18b2c5
while ! [ "x$(/snap/bin/aws ec2 start-instances --region eu-central-1 \
--instance-ids "$WORKER_ID" --output text|grep "CURRENTSTATE" \
|cut -f3)" = "xrunning" ];
do 
	echo "$WORKER_ID not running"
	sleep 60;
done;
export WORKER_IP="$(/snap/bin/aws ec2 describe-instances --output text \
	--region eu-central-1 --instance-ids "$WORKER_ID" \
	--query 'Reservations[*].Instances[*].PublicIpAddress' )"
export WORKER_CONNECT='ubuntu@'"$WORKER_IP"
echo "$WORKER_CONNECT"

# copy all txt files to the processing instance
# setup its ephemeral disk /data if lost 
#lsblk
ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "$WORKER_IP"
ssh -o "StrictHostKeyChecking no" "$WORKER_CONNECT" << SSH
if findmnt --source /dev/xvdb --target /data >/dev/null && [ "x$(stat --format '%U' '/data/txt')" = "xubuntu" ] ;
then echo "/data/txt is mounted to /dev/xvdb owned by ubuntu, proceeding"
else echo "resetting /data"; \
sudo mkfs -t xfs /dev/xvdb; sudo mkdir -p /data; \
sudo mount /dev/xvdb /data; sudo chown ubuntu.ubuntu /data; \
mkdir -p /data/txt; mkdir -p /data/pickles; 
fi
SSH
time rsync -r --size-only --progress /data/txt/ "$WORKER_CONNECT":/data/txt

#rsync -havz --progress /home/ubuntu/arxiv-sanity-preserver/ \
#	"$WORKER_CONNECT":/home/ubuntu/arxiv-sanity-preserver




function run_analyse_on_worker {
FIELDDIR="$1"
scp "$FIELDDIR/db.p" \
"$WORKER_CONNECT":/home/ubuntu/arxiv-sanity-preserver/
time ssh "$WORKER_CONNECT" << SSH
source /home/ubuntu/env/bin/activate; cd /home/ubuntu/arxiv-sanity-preserver/; \
python analyze.py;
SSH
for file in sim_dict.p tfidf.p tfidf_meta.p; do scp \
""$WORKER_CONNECT":/data/pickles/$file" "$FIELDDIR/" ; done;
source "$HOMEDIR/env/bin/activate"; cd "$FIELDDIR"; python "$FIELDDIR/buildsvm.py"; \
python "$FIELDDIR/make_cache.py";
}
export -f run_analyse_on_worker

for FIELD in "${!FIELDS[@]}";
	do
		echo "Trainig SVM for arXiv Field ${FIELDS[$FIELD]}";
		run_analyse_on_worker "$WORKDIR/$FIELD";
	done;

/snap/bin/aws ec2 stop-instances --region eu-central-1 --instance-ids "$WORKER_ID" 
