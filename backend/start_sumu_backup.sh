if ps ax | grep -v grep | grep "python3 serve.py" > /dev/null
then
    exit
else
    cd /Users/amathu4/personal/code/google-photos-clone/backend
    . env/bin/activate
    python3 serve.py
fi
exit
