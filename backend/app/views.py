from app import app, models, db
from flask import request, jsonify
import base64
import uuid
import os
import shutil
import pathlib

# Constants
PW = 'beeblesissuchameerkat'
ENV = os.environ.get('SUMU_BACKUP_ENV') or 'prod'
DEFAULT_ALBUM = 'default'
UUID_LEN = 36

# Filename constants
ROOT_DIR_DEV = '/Users/Mukelyan/sandbox/sumu-backup/backend'
ROOT_DIR_PROD = '/Users/amathu4/temp'
FILENAME_FORMAT = '{timestamp}_{uuid}.{extension}'
USER_DIRECTORY = '{root}' + os.path.sep + '{user}'
DIRECTORY_TO_WRITE_FILES = '{userdir}' + os.path.sep + '{album}'
FILE_PARTS_DIR='tmp'
FILE_PART_NAME = '{dir}' + os.path.sep + '{tmpUuid}_{chunkNum}'
ABS_FILENAME = '{dir}' + os.path.sep + '{filename}'
FAVORITES_DIR_NAME = 'favorites'

def makeError(statusCode, msg=''):
    ret = jsonify({
        'status': statusCode,
        'message': msg
    })
    ret.status_code = statusCode
    return ret

@app.route('/health')
def health():
    print("hello")
    if request.args.get('p') != PW:
        return makeError(500, 'pwnd')
    return jsonify('ok')

def argsTimestamps(params):
    if params.get('p') != PW:
        raise Exception('pwnd')

    user = params.get('u')
    if type(user) is not str or len(user) == 0:
        errMsg = 'user needs to be a nonempty string!'
        raise Exception(errMsg)

    return user

def mapTimesSeenToBool(times, isLive):
    '''There are 3 outcomes: upload, not upload, crash. They corresond to None, True, False.

    If timesSeen is None, frontend should upload. If it's 1 and for a live photo, then upload was
    probably interrupted between the photo and video parts last time, which means we should upload.
    If it was 1 but NOT for a live photo, then the frontend should still upload. If it's 2 but
    they're for the photo and video parts of a live photo, frontend should neither upload nor
    crash. If it's 2 but not for live photo, it should crash. If 3 or greater, it should crash.
    Crashing is so I'm forced to investigate what happened on the backend :-)
    '''
    if times == 1 and isLive:  # upload was prob. interrupted between photo and vid parts
        return None  # None means make the frontend do an upload
    elif times == 1:  # if saw photo or video once and it's not live, makes sense, just skip
        return True  # true means make frontend skip an upload
    elif times == 2 and isLive:  # makes sense, just skip
        return True
    else:  # if saw twice and is not live or saw 3 or more times, doesn't make sense. crash
        return False

def removeMediaFromDiskAndDatabase(rowId):
    row = models.MediaMetadata.query.get(rowId)
    absoluteFilename = row.absoluteFilename
    absoluteFilenameSplit = absoluteFilename.split(os.path.sep)
    filename = absoluteFilenameSplit[-1]
    baseDirectory = os.path.sep.join(absoluteFilenameSplit[0:-2])

    # remove file in favorites directory
    absoluteFavoritePath = pathlib.Path(ABS_FILENAME.format(
        dir=ABS_FILENAME.format(dir=baseDirectory, filename=FAVORITES_DIR_NAME),
        filename=filename
    ))
    if absoluteFavoritePath.exists():
        absoluteFavoritePath.unlink()

    # remove actual file
    absolutePath = pathlib.Path(absoluteFilename)
    if absolutePath.exists():
        absolutePath.unlink()

    # delete row from the database
    db.session.delete(row)
    db.session.commit()

@app.route('/timestamps', methods=['GET'])
def getTimestamps():
    '''Return dict with timestamps mapped to true if exactly 1 row has it, false if > 1 row'''
    try:
        user = argsTimestamps(request.args)
    except Exception as err:
        return makeError(500, str(err))

    # record the number of times each timestamp occurs in the database
    timesSeen = {}
    for row in models.MediaMetadata.query.all():
        if user != row.user:
            continue
        timestamp = row.creationTimestamp
        isLivePhoto = row.isLivePhoto
        if timesSeen.get(timestamp) is None:
            timesSeen[timestamp] = [0, isLivePhoto, row.id]
        timesSeen[timestamp][0] += 1
        timesSeen[timestamp][1] = timesSeen[timestamp][1] and isLivePhoto

    # delete rows and files for partially updated live photo assets. i.e., ones where only the
    # image or only the video was uploaded before the upload was interrupted. this technically
    # violates the spirit of GET endpoints, but whatever
    for [times, isLivePhoto, rowId] in timesSeen.values():
        if times == 1 and isLivePhoto:
            removeMediaFromDiskAndDatabase(rowId)

    ret = {k: mapTimesSeenToBool(times, isLive) for k, [times, isLive, _] in timesSeen.items()}
    return jsonify({k: v for k, v in ret.items() if v is not None})

def getChunkFilename(tmpUuid, chunkNum):
    return FILE_PART_NAME.format(dir=FILE_PARTS_DIR, tmpUuid=tmpUuid, chunkNum=chunkNum)

def processPartJson(body):
    if body.get('p') != PW:
        raise Exception('pwnd')

    chunkNum = body.get('o')
    if type(chunkNum) is not int or chunkNum < 0:
        errMsg = 'Need nonnegative chunk number for file part upload, got {}'.format(chunkNum)
        raise Exception(errMsg)

    tmpUuid = body.get('d')
    if type(tmpUuid) is not str or len(tmpUuid) != UUID_LEN:
        errMsg = 'Need temporary uuid'
        raise Exception(errMsg)

    partFilename = getChunkFilename(tmpUuid, chunkNum)
    return partFilename

@app.route('/part', methods=['POST'])
def uploadPart():
    '''Receive part of image or video'''
    body = request.get_json(silent=True)
    print(body.get('d'))
    # process and validate json body
    try:
        partFilename = processPartJson(body)
    except Exception as err:
        print (err)
        return makeError(500, str(err))

    try:
        # make tmp directory if it doesn't exist yet
        if not pathlib.Path(FILE_PARTS_DIR).is_dir():
            os.mkdir(FILE_PARTS_DIR)

        # write part to tmp directory
        with open(partFilename, 'wb') as fh:
            fh.write(base64.b64decode(body.get('i')))
    except Exception as err:
        print (err)
        return makeError(500, str(err))
    return jsonify('')

def getFilenames(rowDict, album, fileExtension):
    relativeFilename = FILENAME_FORMAT.format(
        timestamp=rowDict.get('creationTimestamp'),
        uuid=rowDict.get('id'),
        extension=fileExtension
    )
    userDirectory = USER_DIRECTORY.format(
        root=ROOT_DIR_PROD if ENV == 'prod' else ROOT_DIR_DEV,
        user=rowDict.get('user')
    )
    directory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=album
    )
    faveDirectory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=FAVORITES_DIR_NAME
    )
    absPath = ABS_FILENAME.format(
        dir=directory,
        filename=relativeFilename
    )
    absFavePath = ABS_FILENAME.format(
        dir=faveDirectory,
        filename=relativeFilename
    )
    return absPath, absFavePath, directory, faveDirectory

def processSaveJson(body):
    if body.get('p') != PW:
        raise Exception('pwnd')

    numParts = body.get('n')
    if type(numParts) is not int or numParts <= 0:
        errMsg = 'Need positive numParts, got {}'.format(numParts)
        raise Exception(errMsg)

    album = body.get('a')
    if type(album) is not str or len(album) == 0:
        errMsg = 'Need nonempty album name'
        raise Exception(errMsg)
    album = '_'.join(album.strip().split())

    tmpUuid = body.get('d')
    if type(tmpUuid) is not str or len(tmpUuid) != UUID_LEN:
        errMsg = 'Need temporary uuid'
        raise Exception(errMsg)

    fileExtension = body.get('x')
    if type(fileExtension) is not str or len(fileExtension) == 0:
        errMsg = 'Need nonempty file suffix'
        raise Exception(errMsg)

    # map from wire model
    rowDict = {
        'id': str(uuid.uuid4()),
        'user': body.get('u'),
        'creationTimestamp': body.get('t'),
        'locationLatitude': body.get('lat'),
        'locationLongitude': body.get('long'),
        'isFavorite': body.get('f'),
        'isVideo': body.get('v'),
        'isLivePhoto': body.get('l')
    }
    absPath, absFavePath, directory, faveDirectory = getFilenames(rowDict, album, fileExtension)
    rowDict['absoluteFilename'] = absPath

    # validate the metadata then make the MediaMetadata object
    if (not models.MediaMetadata.validate(rowDict)):
        errMsg = 'Metadata validation failed: {}'.format(rowDict)
        raise Exception(errMsg)
    row = models.MediaMetadata.fromDict(rowDict)

    return numParts, tmpUuid, row, absFavePath, directory, faveDirectory

@app.route('/save', methods=['POST'])
def combinePartsAndSave():
    '''When parts are received, concat them, store result in plex dir, and write metadata to DB'''
    body = request.get_json(silent=True)

    # process and validate json body
    try:
        numParts, tmpUuid, row, absFavePath, directory, faveDirectory = processSaveJson(body)
    except Exception as err:
        print (err)
        return makeError(500, str(err))

    # check that all expected file parts exist
    print(tmpUuid)
    
    filePartsArr = [getChunkFilename(tmpUuid, chunkNum) for chunkNum in range(1, numParts + 1)]
    
    filePartExists = [os.path.isfile(filename) for filename in filePartsArr]
    if not all(filePartExists):
        fileExistence = {file: exists for (file, exists) in zip(filePartsArr, filePartExists)}
        errMsg = 'Not all expected parts were there! {}'.format(fileExistence)
        print (errMsg)
        return makeError(500, errMsg)

    try:
        # combine file parts and store results in album directory
        if not pathlib.Path(directory).is_dir():
            os.mkdir(directory)
        with open(row.absoluteFilename, 'wb') as wfd:
            for f in filePartsArr:
                with open(f, 'rb') as fd:
                    shutil.copyfileobj(fd, wfd)

        # remove temporary files
        for filename in filePartsArr:
            os.remove(filename)

        # copy into favorites directory if it's a favorite
        if not pathlib.Path(faveDirectory).is_dir():
            os.mkdir(faveDirectory)
        if row.isFavorite:
            shutil.copyfile(row.absoluteFilename, absFavePath)

        # put a metadata row in the DB
        db.session.add(row)
        db.session.commit()

    except Exception as err:
        print (err)
        return makeError(500, str(err))

    return jsonify('')
