//
//  ViewController.swift
//  myPhoto
//
//  Created by Abhinav Mathur - AMATHU4 on 5/27/21.
//

import UIKit
import Photos

class ViewController: UIViewController {

    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var startBackupButton: UIButton!
    
   var asyncNetworkCallMutex = DispatchSemaphore(value: 2)
    var asyncNetworkCallDispatchGroupMap = [String:DispatchGroup]()
    var finalizeMultipartUploadMutex = DispatchSemaphore(value:1)
     var assetUploadedMutex = DispatchSemaphore(value: 1)
    var results:PHFetchResult<PHAsset> = PHFetchResult<PHAsset>()
    
    
    var isServerOnline = false {  // keep checking if the server is online every few seconds
        didSet {
            isServerOnlineWatcherTasks(newValue: isServerOnline)

            // Keep performing a liveness check in case the connection goes down
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.RETRY_SERVER_HEALTH_CHECK_INTERVAL_SECS) {
                self.checkIsServerOnline()
            }
        }
    }
    
    
    // Set isServerOnline, which kicks off some watcher tasks AND schedules another checkIsServerOnline call for a few seconds later. Set setInstanceVariable to false to kick off watcher tasks WITHOUT scheduling another checkIsServerOnline call, which is useful if you have to manually call this function instead of relying on the automatically scheduled ones initiated by the call in viewDidLoad. This method is async if setInstanceVariable is true, synchronous otherwise (controlled by beforeFinishingLastUploadMutex)
    func checkIsServerOnline(setInstanceVariable: Bool = true) {
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "health"))
        req.httpMethod = "GET"
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            DispatchQueue.main.async {
                let newValue = error == nil ? true : false
                if (setInstanceVariable) {
                    self.isServerOnline = newValue
                } else {
                    self.isServerOnlineWatcherTasks(newValue: newValue)
                }
            }
        }).resume()
    }
    
    func setUploadButtons(enable: Bool) {
        startBackupButton.isEnabled = enable
    }
    
    func isServerOnlineWatcherTasks(newValue: Bool) {
        if newValue {  // if server is online
            statusLabel.text = Constants.WELCOME_MSG
            setUploadButtons(enable: true)
        } else {  // if server is unreachable
            statusLabel.text = Constants.SERVER_OFFLINE_MSG
            setUploadButtons(enable: true)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        // Do any additional setup after loading the view.
        statusLabel.numberOfLines = 20
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.text = Constants.CHECKING_SERVER_MSG
        
        checkIsServerOnline()
    }
    
    
    func getMedia()->[PHAsset] {
        statusLabel.text = "Fetching assets"
        var assets:[PHAsset] = []
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAllBurstAssets = false
        
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared,.typeUserLibrary,.typeiTunesSynced]
        results = PHAsset.fetchAssets(with:.image,options: fetchOptions)
        for i in 0..<results.count {
            autoreleasepool{
                assets.append((results[i]))
            }
        }
        results = PHAsset.fetchAssets(with:.video,options: fetchOptions)
        for i in 0..<results.count {
            autoreleasepool{
                assets.append((results[i]))
            }
        }
        results = PHAsset.fetchAssets(with:.audio,options: fetchOptions)
        for i in 0..<results.count {
            autoreleasepool{
                assets.append((results[i]))
            }
        }
        results = PHAsset.fetchAssets(with:.unknown,options: fetchOptions)
        for i in 0..<results.count {
            autoreleasepool{
                assets.append((results[i]))
            }
        }

        statusLabel.text = "Fetched assets"
        assetsToUpload = assets
        return assets
        
    }
    
    var assetsToUpload = [PHAsset]()
    func uploadMedia() {
        statusLabel.text = Constants.PREPARING_UPLOAD
        //TODO load and create DS from past uploads status
         self.getMedia()
         self.statusLabel.text = "Total Assets \(self.assetsToUpload.count)"
         for asset in self.assetsToUpload {
                 
            handleAsset(asset: asset, mediaType: asset.mediaType, isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
            
          }
            
       
    }
    
    func getUrl(endpoint: String) -> URL {
        var urlStringWithoutParams = ""
        var params = ""
        let passParam = "?p=" + Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL
        switch endpoint {
        case "health":
            urlStringWithoutParams = Constants.HEALTH_URL
            params = passParam
        case "timestamps":
            urlStringWithoutParams = Constants.TIMESTAMPS_URL
            params = passParam + "&u=" + "vicky"
        case "part":
            urlStringWithoutParams = Constants.PART_URL
        case "save":
            urlStringWithoutParams = Constants.SAVE_URL
        default:
            print("Unsupported endpoint:", endpoint)
            exit(1)
        }
        return URL(string: urlStringWithoutParams + params)!
    }
    
    
    func sendChunkOverWire(d:Data,uuid:String,chunkNum:Int)->Bool {
        asyncNetworkCallMutex.wait()
        asyncNetworkCallDispatchGroupMap[uuid]?.enter()
        let session = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "part"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "p": Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "i": d.base64EncodedString(),
            "d": uuid,
            "o": chunkNum,
        ]
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
        req.httpBody = data
        var ret = false
        let completionHandler = {(data:Data?,response:URLResponse?,e:Error?)-> Void in
            if e != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Chunk upload failed. Error:", e ?? "nil error")
                ret = ret && false
            } else {
                ret = true
            }
            self.asyncNetworkCallMutex.signal()
            self.asyncNetworkCallDispatchGroupMap[uuid]?.leave()
        }
       
        let dataTask = session.dataTask(with: req,completionHandler: completionHandler)
        dataTask.resume()
        
        return ret
    }
    
    func finalizeMultipartUpload(numParts:Int,fileExtension:String,mediaType:PHAssetMediaType, uuid:String,isLivePhoto:Bool)->Bool {
        finalizeMultipartUploadMutex.wait()
        let sesh = URLSession(configuration: .default)
        var req = URLRequest(url: getUrl(endpoint: "save"))
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpMethod = "POST"
        let jsonObj: [String: Any?] = [
            "a": "aaa", // second part of relative path on server
            "p": Constants.HARD_CODED_PASSWORD_HOW_SHAMEFUL,
            "u": "vicky",  // user name, used as first path of relative path on server where photos will be stored
            "t": 1234,
            "lat": 1244,
            "long": 1234,
            "f": true,
            "v": (mediaType == .image ? false : true),
            "d": uuid,
            "n": numParts,
            "l": isLivePhoto,
            "x": fileExtension
        ]
        var failed = false
        let data = try! JSONSerialization.data(withJSONObject: jsonObj, options: .fragmentsAllowed)
       
        req.httpBody = data
        _ = sesh.dataTask(with: req, completionHandler: { (data, response, error) in
            if error != nil || (response as! HTTPURLResponse).statusCode != 200 {
                print ("Final multipart call failed. Error:", error ?? "nil error")
              //  print((response as! HTTPURLResponse).statusCode )
                failed = true
            }
            print("END ---------------------------\(uuid)")
            self.finalizeMultipartUploadMutex.signal()
            self.assetUploadedMutex.signal()
          
        }).resume()
        
        return !failed

    }
    
    func handleAsset(asset:PHAsset,mediaType:PHAssetMediaType,isLivePhoto:Bool)->Void {
        
        let finalAssetResource = getFinalAssetResource(asset: asset,  mediaType: mediaType, isLivePhoto: isLivePhoto)
        let filename = finalAssetResource == nil ? "" : finalAssetResource!.originalFilename
        statusLabel.text = "Uploading \(filename)"
        let splitFilename = filename.split(separator: ".")
        let fileExtension = splitFilename.count == 0 ? "" : String(splitFilename[splitFilename.count - 1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let multipartUploadUuid = UUID().uuidString
        if  finalAssetResource == nil {
            assetUploadedMutex.signal()
                
        } else {
            let managerRequestOptions = PHAssetResourceRequestOptions()
            managerRequestOptions.isNetworkAccessAllowed = true
            let manager = PHAssetResourceManager.default()
            var data:[Data] = []
            var num:Int = 0
           
            print("Start-------------------------\(multipartUploadUuid)")
            let dataReceivedHandler = { (dataChunk:Data)-> Void in
                data.append(dataChunk)
            }
            var dispatchGroup = DispatchGroup()
            asyncNetworkCallDispatchGroupMap[multipartUploadUuid] = dispatchGroup
            let completionHandler = { (e:Error?)->Void in
                if(e != nil) {
                    self.statusLabel.text = "Failed Uploading \(filename)"
                } else {
                   
                    for d in data {
                        var retry = 0
                        num = num+1
                        var ret = self.sendChunkOverWire(d: d, uuid: multipartUploadUuid, chunkNum: num)
                        while(ret == false && retry < 3) {
                            retry = retry + 1
                            ret = self.sendChunkOverWire(d: d, uuid: multipartUploadUuid, chunkNum: num)
                        }
                        
                    }
                    print("done\(num)")
                    dispatchGroup.wait()
                    if(num>=1) {
                        var fe = fileExtension == "heic" ? ".heic" : fileExtension
                        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
                        var done = self.finalizeMultipartUpload(numParts: num, fileExtension: fe, mediaType: PHAssetMediaType.image, uuid: multipartUploadUuid,isLivePhoto: isLivePhoto)
                        if(done) {
                           /* PHPhotoLibrary.shared().performChanges({
                                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                            })*/
                        }
                    }
                    
            }
            }
            manager.requestData(for: finalAssetResource!, options: managerRequestOptions,dataReceivedHandler: dataReceivedHandler,completionHandler:completionHandler )
            
           
        
        }
        
        
        
        
        
    }
    
    
    
    // Find the desired asset resource FROM DISK. There are many resource types, like .photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo.
    func getFinalAssetResource(asset:PHAsset,mediaType:PHAssetMediaType,isLivePhoto:Bool)->PHAssetResource? {
        
        // Determine preferred and backup resource types
        var preferredResourceType = mediaType == .video ? PHAssetResourceType.fullSizeVideo : PHAssetResourceType.fullSizePhoto
        var backupResourceType = mediaType == .video ? PHAssetResourceType.video : PHAssetResourceType.photo
        if isLivePhoto && mediaType == .video {  // if this request is for the video part of a live photo
            preferredResourceType = .fullSizePairedVideo
            backupResourceType = .pairedVideo
        }

        // Find the desired asset resource
        let assetResources = PHAssetResource.assetResources(for: asset)
        var chosenAssetResource: PHAssetResource?
        for assetResource in assetResources {
            if assetResource.type == preferredResourceType {
                chosenAssetResource = assetResource
            }
            if assetResource.type == backupResourceType && chosenAssetResource == nil {
                chosenAssetResource = assetResource
            }
        }
        if chosenAssetResource == nil {
            print ("Couldn't find preferred or backup asset resource; it probably needs to be downloaded from the cloud. Local resources for this asset were", assetResources)
            print ("Asked for", preferredResourceType, backupResourceType)
        }
        return chosenAssetResource
    }
    
    
    
    @IBAction func startBackupPressed(_ sender: Any) {
        uploadMedia()
    }
    
    
   

      

}

