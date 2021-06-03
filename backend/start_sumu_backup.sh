if ps ax | grep -v grep | grep "python3 serve.py" > /dev/null
then
    exit
else
    cd /Users/amathu4/Downloads/sumu-backup-master/backend
    . sumu_env/bin/activate
    python3 serve.py
fi
exit
