//
//  ViewController.swift
//  myPhoto
//
//
// Upload in main UI thread one file at a time to server by chunking it

import UIKit
import Photos

class ViewController1: UIViewController {

    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var startBackupButton: UIButton!
    
    //only one call to server at a timme
    var makeNetworkCallMutex = DispatchSemaphore(value: 1)
    //only one file at a time
    var assetUploadedMutex = DispatchSemaphore(value: 1)
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true
        // Do any additional setup after loading the view.
        statusLabel.numberOfLines = 20
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.text = Constants.CHECKING_SERVER_MSG
    }
    
    func getMedia()->[PHAsset] {
        statusLabel.text = "Fetching assets"
        var assets:[PHAsset] = []
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAllBurstAssets = false
        fetchOptions.includeAssetSourceTypes = [.typeCloudShared,.typeUserLibrary,.typeiTunesSynced]
        let results = PHAsset.fetchAssets(with:.image,options: fetchOptions)
        for i in 0..<results.count {
            assets.append((results[i]))
        }
        statusLabel.text = "Fetched assets"
        return assets
        
    }
    
    func uploadMedia() {
        statusLabel.text = Constants.PREPARING_UPLOAD
        //TODO load and create DS from past uploads status
        let assetsToUpload = getMedia()
        var i=1
        for asset in assetsToUpload {
            assetUploadedMutex.wait()
            handleAsset(asset:asset)
            i = i+1
            
        }
        statusLabel.text = "FINISHED"
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
        makeNetworkCallMutex.wait()
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
            self.makeNetworkCallMutex.signal()
        }
       
        let dataTask = session.dataTask(with: req,completionHandler: completionHandler)
        dataTask.resume()
        
        return ret
    }
    
    func finalizeMultipartUpload(numParts:Int,fileExtension:String,mediaType:PHAssetMediaType, uuid:String)->Bool {
        makeNetworkCallMutex.wait()
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
            "l": false,
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
            self.makeNetworkCallMutex.signal()
            self.assetUploadedMutex.signal()
          
        }).resume()
        
        return true

    }
    
    func handleAsset(asset:PHAsset)->Void {
        
        let finalAssetResource = getFinalAssetResource(asset: asset,  mediaType: .image, isLivePhoto: false)
        let filename = finalAssetResource == nil ? "" : finalAssetResource!.originalFilename
        statusLabel.text = "Uploading \(filename)"
        let splitFilename = filename.split(separator: ".")
        let fileExtension = splitFilename.count == 0 ? "" : String(splitFilename[splitFilename.count - 1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if fileExtension == "heic" || finalAssetResource == nil {
            assetUploadedMutex.signal() //TODO: remove it when you add logic here
        } else {
            let managerRequestOptions = PHAssetResourceRequestOptions()
            managerRequestOptions.isNetworkAccessAllowed = true
            let manager = PHAssetResourceManager.default()
            var data:[Data] = []
            var num:Int = 0
            let multipartUploadUuid = UUID().uuidString
            print("Start-------------------------\(multipartUploadUuid)")
            let dataReceivedHandler = { (dataChunk:Data)-> Void in
                data.append(dataChunk)
            }
            
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
                    if(num>=1) {
                        self.finalizeMultipartUpload(numParts: num, fileExtension: ".jpeg", mediaType: PHAssetMediaType.image, uuid: multipartUploadUuid)
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
        print(chosenAssetResource?.assetLocalIdentifier)
        print(chosenAssetResource?.originalFilename)
        return chosenAssetResource
        
        
    }
    
    
    
    @IBAction func startBackupPressed(_ sender: Any) {
        uploadMedia()
    }
    

}

