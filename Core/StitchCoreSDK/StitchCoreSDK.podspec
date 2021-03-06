Pod::Spec.new do |spec|
    spec.name       = File.basename(__FILE__, '.podspec')
    spec.version    = "4.1.2"
    spec.summary    = "#{__FILE__} Module"
    spec.homepage   = "https://github.com/mongodb/stitch-ios-sdk"
    spec.license    = "Apache2"
    spec.authors    = {
      "Jason Flax" => "jason.flax@mongodb.com",
      "Adam Chelminski" => "adam.chelminski@mongodb.com",
      "Eric Daniels" => "eric.daniels@mongodb.com",
    }

    spec.source = {
      :git => "https://github.com/mongodb/stitch-ios-sdk.git",
      :branch => "master", :tag => "4.1.2"
      
    }

    spec.platform = :ios, "11.0"
    spec.swift_version = '4.2'

    spec.ios.deployment_target = "11.0"

    spec.dependency 'MongoSwift', '=0.0.7'
    
    spec.source_files = "Core/#{spec.name}/Sources/#{spec.name}/**/*.swift"
end
