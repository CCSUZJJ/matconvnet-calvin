function fcnTrainGeneric(varargin)
% fcnTrainGeneric(varargin)
%
% Train FCN model using MatConvNet.
%
% Copyright by Holger Caesar, 2016

% Initial settings
p = inputParser;
addParameter(p, 'dataset', SiftFlowDataset());
addParameter(p, 'modelType', 'fcn16s');
addParameter(p, 'gpus', 2);
addParameter(p, 'randSeed', 42);
addParameter(p, 'expNameAppend', 'test');
addParameter(p, 'weaklySupervised', false);
addParameter(p, 'numEpochs', 50);
addParameter(p, 'useInvFreqWeights', false);
addParameter(p, 'wsUseAbsent', false);
addParameter(p, 'wsUseScoreDiffs', false);
addParameter(p, 'wsEqualWeight', false);
addParameter(p, 'semiSupervised', false);
addParameter(p, 'semiSupervisedRate', 0.1); % ratio of images with full supervision
addParameter(p, 'semiSupervisedOnlyFS', false); % use only the x% fully supervised images
addParameter(p, 'initIlsvrc', false);
addParameter(p, 'initLinComb', false);
addParameter(p, 'initAutoBias', false);
addParameter(p, 'enableCudnn', true);
parse(p, varargin{:});

dataset = p.Results.dataset;
modelType = p.Results.modelType;
gpus = p.Results.gpus;
randSeed = p.Results.randSeed;
expNameAppend = p.Results.expNameAppend;
weaklySupervised = p.Results.weaklySupervised;
numEpochs = p.Results.numEpochs;
useInvFreqWeights = p.Results.useInvFreqWeights;
wsUseAbsent = p.Results.wsUseAbsent;
wsUseScoreDiffs = p.Results.wsUseScoreDiffs;
wsEqualWeight = p.Results.wsEqualWeight;
semiSupervised = p.Results.semiSupervised;
semiSupervisedRate = p.Results.semiSupervisedRate;
semiSupervisedOnlyFS = p.Results.semiSupervisedOnlyFS;
initIlsvrc = p.Results.initIlsvrc;
initLinComb = p.Results.initLinComb;
initAutoBias = p.Results.initAutoBias;
enableCudnn = p.Results.enableCudnn;
callArgs = p.Results; %#ok<NASGU>

% Check settings for consistency
if semiSupervised
    assert(weaklySupervised);
end
if isa(dataset, 'VOC2011Dataset')
    assert(~useInvFreqWeights);
end;

% experiment and data paths
global glBaseFolder glFeaturesFolder;
dataRootDir = fullfile(glBaseFolder, 'CodeForeign', 'CNN', 'matconvnet-fcn', 'data');
expName = [modelType, prependNotEmpty(expNameAppend, '-')];
opts.expDir = fullfile(glFeaturesFolder, 'CNN-Models', 'FCN', dataset.name, expName);
% opts.sourceModelPath = fullfile(glFeaturesFolder, 'CNN-Models', 'matconvnet', '17beta', 'imagenet-vgg-verydeep-16.mat');
opts.sourceModelPath = fullfile(glFeaturesFolder, 'CNN-Models', 'matconvnet', '17beta', 'imagenet-matconvnet-vgg-verydeep-16.mat');
% opts.sourceModelPath = fullfile(dataRootDir, 'models', 'imagenet-vgg-verydeep-16.mat');
logFilePath = fullfile(opts.expDir, 'log.txt');
initLinCombPath = fullfile(glFeaturesFolder, 'CNN-Models', 'FCN', dataset.name, 'fcn16s-notrain-ilsvrc-auto-lincomb-trn', 'linearCombination-trn.mat');
modelPathFunc = @(epoch) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', epoch));

% training options (SGD)
existingEpoch = CalvinNN.findLastCheckpoint(opts.expDir);
opts.train.batchSize = 20;
opts.train.numSubBatches = opts.train.batchSize;
opts.train.continue = existingEpoch > 0;
opts.train.gpus = gpus;
opts.train.prefetch = true;
opts.train.expDir = opts.expDir;
opts.train.numEpochs = numEpochs;
opts.train.learningRate = 1e-4;
opts.modelType = modelType;

% Fix randomness
rng(randSeed);

% Create folders
if ~exist(opts.expDir, 'dir'),
    mkdir(opts.expDir);
end;

% Setup logfile
diary(logFilePath);

% -------------------------------------------------------------------------
% Setup data
% -------------------------------------------------------------------------

opts.imdbPath = fullfile(opts.expDir, 'imdb.mat');
if exist(opts.imdbPath, 'file')
    imdb = load(opts.imdbPath);
else
    % Dataset-specific imdb creation
    if strStartsWith(dataset.name, 'VOC'),
        % Get PASCAL VOC 12 segmentation dataset plus Berkeley's additional
        % segmentations
        opts.vocAdditionalSegmentations = true;
        opts.vocEdition = '11';
        opts.dataDir = fullfile(dataRootDir, dataset.name);
        imdb = vocSetup('dataDir', opts.dataDir, ...
            'edition', opts.vocEdition, ...
            'includeTest', false, ...
            'includeSegmentation', true, ...
            'includeDetection', false);
        if opts.vocAdditionalSegmentations
            imdb = vocSetupAdditionalSegmentations(imdb, 'dataDir', opts.dataDir);
        end
        labelCount = 21;
    else
        % Imdb must have the following fields:
        % imdb.images.name, imdb.classes.name, imdb.labelCount, imdb.dataset
        
        % Get labels and image path
        [imdb.classes.name, labelCount] = dataset.getLabelNames();
        imdb.paths.image = fullfile(dataset.getImagePath(), sprintf('%%s%s', dataset.imageExt));
    end;
    
    % Dataset-independent imdb fields
    imdb.dataset = dataset;
    imdb.labelCount = labelCount;
    imdb.weaklySupervised = weaklySupervised;
    imdb.semiSupervised = semiSupervised;
    imdb.semiSupervisedRate = semiSupervisedRate;
    imdb.useInvFreqWeights = useInvFreqWeights;
    
    % Specify level of supervision for each image
    imdb.images.isFullySupervised = true(1, numel(imdb.images.name));
    if semiSupervised
        perm = randperm(numel(imdb.images.name));
        imdb.images.isFullySupervised = perm / numel(imdb.images.name) <= semiSupervisedRate;
        
        if semiSupervisedOnlyFS
            % Keep x% of train and all val
            sel = imdb.images.isFullySupervised(:) | imdb.images.set(:) == 2;
            imdb.images.id = imdb.images.id(sel);
            imdb.images.name = imdb.images.name(sel);
            imdb.images.set = imdb.images.set(sel);
            imdb.images.classification = imdb.images.classification(sel);
            imdb.images.segmentation = imdb.images.segmentation(sel);
            imdb.images.size = imdb.images.size(:, sel);
            imdb.images.isFullySupervised = imdb.images.isFullySupervised(sel);
        end
    end
    
    % Save imdb
    save(opts.imdbPath, '-struct', 'imdb');
end;

if strStartsWith(dataset.name, 'VOC'),
    % Get training and test/validation subsets
    % We always validate and test on val
    train = find(imdb.images.set == 1 & imdb.images.segmentation);
    val = find(imdb.images.set == 2 & imdb.images.segmentation);
    
    % Get mean image
    % Get dataset statistics
    opts.imdbStatsPath = fullfile(opts.expDir, 'imdbStats.mat');
    if exist(opts.imdbStatsPath, 'file')
        stats = load(opts.imdbStatsPath);
    else
        stats = getDatasetStatistics(imdb);
        save(opts.imdbStatsPath, '-struct', 'stats');
    end
    
    % Batch options
    rgbMean = stats.rgbMean;
    translateLabels = true;
else
    % Get trn+val images
    imageList = dataset.getImageListTrn();
    
    % Remove images without labels
    if true
        missingImageIndices = dataset.getMissingImageIndices('train');
        imageList(missingImageIndices) = [];
        imageCount = numel(imageList);
    end
    
    % Get training and test/validation subsets
    perm = randperm(imageCount)';
    split = round(0.9 * imageCount);
    train = perm(1:split);
    val = perm(split+1:end);
    
    imdb.images.name = imageList;
    rgbMean = imdb.dataset.getMeanColor();
    translateLabels = false;
end;


% -------------------------------------------------------------------------
% Setup model
% -------------------------------------------------------------------------

if existingEpoch == 0
    netStruct = load(modelPathFunc(existingEpoch), 'net');
    net = dagnn.DagNN.loadobj(netStruct.net);
    clearvars netStruct;
elseif existingEpoch > 0
    net = {};
elseif isnan(existingEpoch)
    % Get initial model from VGG-VD-16
    net = fcnInitializeModelGeneric(imdb.labelCount, 'sourceModelPath', opts.sourceModelPath, 'initIlsvrc', initIlsvrc, 'initLinComb', initLinComb, 'initLinCombPath', initLinCombPath, 'initAutoBias', initAutoBias, 'enableCudnn', enableCudnn);
    if any(strcmp(opts.modelType, {'fcn16s', 'fcn8s'}))
        % upgrade model to FCN16s
        net = fcnInitializeModel16sGeneric(imdb.labelCount, net);
    end
    if strcmp(opts.modelType, 'fcn8s')
        % upgrade model fto FCN8s
        net = fcnInitializeModel8sGeneric(imdb.labelCount, net);
    end
    net.meta.normalization.rgbMean = rgbMean;
    net.meta.classes = imdb.classes.name;
    
    if weaklySupervised
        wsPresentWeight = 1 / (1 + wsUseAbsent);
        
        if wsEqualWeight
            wsAbsentWeight = imdb.labelCount * wsUseAbsent; % TODO: try -log(2/21) / -log(1-2/21)
        else
            wsAbsentWeight = 1 - wsPresentWeight;
        end
    end
    
    if ~semiSupervised
        if weaklySupervised
            % Replace loss by weakly supervised instance-weighted loss
            objIdx = net.getLayerIndex('objective');
            assert(strcmp(net.layers(objIdx).block.loss, 'softmaxlog'));
            objInputs = [net.layers(objIdx).inputs(1), {'labelsImage', 'classWeights'}];
            objOutputs = net.layers(objIdx).outputs;
            net.removeLayer('objective');
            net.addLayer('objective', dagnn.SegmentationLossImage('useAbsent', wsUseAbsent, 'useScoreDiffs', wsUseScoreDiffs, 'presentWeight', wsPresentWeight, 'absentWeight', wsAbsentWeight), objInputs, objOutputs, {});
            
            % Remove accuracy layer if no pixel-level labels exist
            if ~imdb.dataset.annotation.hasPixelLabels,
                net.removeLayer('accuracy');
            end;
        else
            % Replace loss by pixel-weighted loss
            objIdx = net.getLayerIndex('objective');
            assert(strcmp(net.layers(objIdx).block.loss, 'softmaxlog'));
            objInputs = [net.layers(objIdx).inputs, {'classWeights'}];
            objOutputs = net.layers(objIdx).outputs;
            net.removeLayer('objective');
            net.addLayer('objective', dagnn.SegmentationLossPixel(), objInputs, objOutputs, {});
        end;
    else
        % Add a layer that automatically decides whether to use FS or WS
        objIdx = net.getLayerIndex('objective');
        assert(strcmp(net.layers(objIdx).block.loss, 'softmaxlog'));
        layerFS = dagnn.SegmentationLossPixel();
        layerWS = dagnn.SegmentationLossImage('useAbsent', wsUseAbsent, 'useScoreDiffs', wsUseScoreDiffs, 'presentWeight', wsPresentWeight, 'absentWeight', wsAbsentWeight);
        objBlock = dagnn.SegmentationLossSemiSupervised('layerFS', layerFS, 'layerWS', layerWS);
        objInputs = [net.layers(objIdx).inputs, {'labelsImage', 'classWeights', 'isWeaklySupervised'}];
        objOutputs = net.layers(objIdx).outputs;
        net.removeLayer('objective');
        net.addLayer('objective', objBlock, objInputs, objOutputs, {});
        
        % Remove accuracy layer if no pixel-level labels exist
        if ~imdb.dataset.annotation.hasPixelLabels
            net.removeLayer('accuracy');
        end
    end
    
    % Replace accuracy layer with 21 classes by flexible accuracy layer
    if imdb.dataset.annotation.hasPixelLabels
        accIdx = net.getLayerIndex('accuracy');
        accLayer = net.layers(accIdx);
        accInputs = accLayer.inputs;
        accOutputs = accLayer.outputs;
        accBlock = dagnn.SegmentationAccuracyFlexible('labelCount', imdb.labelCount);
        net.removeLayer('accuracy');
        net.addLayer('accuracy', accBlock, accInputs, accOutputs, {});
    end
end

% Extract inverse class frequencies from dataset
if useInvFreqWeights,
    if weaklySupervised,
        classWeights = imdb.dataset.getLabelImFreqs('train');
    else
        classWeights = imdb.dataset.getLabelPixelFreqs('train');
    end;
    
    % Inv freq and normalize classWeights
    classWeights = classWeights ./ sum(classWeights);
    nonEmpty = classWeights ~= 0;
    classWeights(nonEmpty) = 1 ./ classWeights(nonEmpty);
    classWeights = classWeights ./ sum(classWeights);
    assert(~any(isnan(classWeights)));
else
    classWeights = [];
end;

% -------------------------------------------------------------------------
% Train
% -------------------------------------------------------------------------

% Setup data fetching options
bopts.labelStride = 1;
bopts.labelOffset = 1;
bopts.classWeights = classWeights;
bopts.rgbMean = rgbMean;
bopts.useGpu = numel(opts.train.gpus) > 0;
if ~strStartsWith(imdb.dataset.name, 'VOC'),
    bopts.imageNameToLabelMap = @(imageName, imdb) imdb.dataset.getImLabelMap(imageName);
end;
bopts.translateLabels = translateLabels;

% Save important settings
settingsPath = fullfile(opts.expDir, 'settings.mat');
save(settingsPath, 'callArgs', 'opts', 'bopts');

% Save net before training
if isnan(existingEpoch)
    saveStruct.net = net.saveobj();
    saveStruct.stats = []; %#ok<STRNU>
    modelPath = modelPathFunc(0);
    assert(~exist(modelPath, 'file'));
    save(modelPath, '-struct', 'saveStruct');
    clearvars saveStruct;
end

% Launch SGD
[~, stats] = cnn_train_dag(net, imdb, getBatchWrapper(bopts), opts.train, ...
    'train', train, ...
    'val', val); %#ok<ASGLU>

% Output stats
statsPath = fullfile(opts.expDir, 'stats.mat');
save(statsPath, 'stats');

% -------------------------------------------------------------------------
function fn = getBatchWrapper(opts)
% -------------------------------------------------------------------------
fn = @(imdb,batch) getBatch(imdb,batch,opts,'prefetch',nargout==0);

function y = getBatch(imdb, images, varargin)
% GET_BATCH  Load, preprocess, and pack images for CNN evaluation

opts.imageSize = [512, 512] - 128;
opts.numAugments = 1;
opts.transformation = 'none';
opts.rgbMean = [];
opts.rgbVariance = zeros(0,3,'single');
opts.labelStride = 1;
opts.labelOffset = 0;
opts.classWeights = [];
opts.interpolation = 'bilinear';
opts.prefetch = false;
opts.useGpu = false;
opts.imageNameToLabelMap = @(imageName, imdb) imread(sprintf(imdb.paths.classSegmentation, imageName));
opts.translateLabels = true;
opts = vl_argparse(opts, varargin);

if opts.prefetch
    % to be implemented
    y = {};
    return;
end

imageCount = numel(images);
assert(imageCount == 1);

if ~isempty(opts.rgbVariance) && isempty(opts.rgbMean)
    opts.rgbMean = single([128;128;128]);
end
if ~isempty(opts.rgbMean)
    opts.rgbMean = reshape(opts.rgbMean, [1 1 3]);
end

% space for images
ims = zeros(opts.imageSize(1), opts.imageSize(2), 3, ...
    imageCount*opts.numAugments, 'single');

% space for labels
lx = opts.labelOffset : opts.labelStride : opts.imageSize(2);
ly = opts.labelOffset : opts.labelStride : opts.imageSize(1);
labels = zeros(numel(ly), numel(lx), 1, imageCount*opts.numAugments, 'double'); % must be double for to avoid numerical precision errors in vl_nnloss, when using many classes
if imdb.weaklySupervised,
    labelsImage = cell(size(labels, 4), 1);
end;

si = 1;

for i = 1 : imageCount
    
    % acquire image
    imageName = imdb.images.name{images(i)};
    rgb = double(imdb.dataset.getImage(imageName)) * 255;
    if size(rgb,3) == 1
        rgb = cat(3, rgb, rgb, rgb);
    end
    
    % acquire pixel-level GT
    if imdb.dataset.annotation.hasPixelLabels,
        anno = uint16(opts.imageNameToLabelMap(imageName, imdb));
        
        % Translate labels s.t. 255 is mapped to 0
        if opts.translateLabels,
            % Before: 255 = ignore, 0 = bkg, 1:labelCount = classes
            % After : 0 = ignore, 1 = bkg, 2:labelCount+1 = classes
            anno = mod(anno + 1, 256);
        end;
        % 0 = ignore, 1:labelCount = classes
    end;
    
    % crop & flip
    h = size(rgb,1);
    w = size(rgb,2);
    for ai = 1:opts.numAugments
        sz = opts.imageSize(1:2);
        scale = max(h/sz(1), w/sz(2));
        scale = scale .* (1 + (rand(1)-.5)/5);
        
        sy = round(scale * ((1:sz(1)) - sz(1)/2) + h/2);
        sx = round(scale * ((1:sz(2)) - sz(2)/2) + w/2);
        if rand > 0.5, sx = fliplr(sx); end
        
        okx = find(1 <= sx & sx <= w);
        oky = find(1 <= sy & sy <= h);
        if ~isempty(opts.rgbMean)
            ims(oky, okx, :, si) = bsxfun(@minus, rgb(sy(oky), sx(okx), :), opts.rgbMean);
        else
            ims(oky, okx, :, si) = rgb(sy(oky), sx(okx),:);
        end
        
        % Fully supervised: Get pixel level labels
        if imdb.dataset.annotation.hasPixelLabels,
            tlabels = zeros(sz(1), sz(2), 'double');
            tlabels(oky,okx) = anno(sy(oky), sx(okx));
            tlabels = single(tlabels(ly,lx));
            labels(:, :, 1, si) = tlabels; % 0: ignore
        end;
        
        % Weakly supervised: extract image-level labels
        if imdb.weaklySupervised,
            if imdb.dataset.annotation.hasPixelLabels,
                % Get image labels from pixel labels
                % These are already translated (if necessary)
                curLabelsImage = unique(anno);
            else
                curLabelsImage = imdb.dataset.getImLabelInds(imageName);
                
                if isa(imdb.dataset, 'VOC2011Dataset')
                    % Add background label
                    curLabelsImage = unique([0; curLabelsImage(:)]);
                end
                
                % Translate labels s.t. 255 is mapped to 0
                if opts.translateLabels
                    curLabelsImage = mod(curLabelsImage + 1, 256);
                end
            end;
            
            % Remove invalid pixels
            curLabelsImage(curLabelsImage == 0) = [];
            
            % Store image-level labels
            labelsImage{si} = single(curLabelsImage(:));
        end;
        
        si = si + 1;
    end
end

% Move image to GPU
if opts.useGpu
    ims = gpuArray(ims);
end

%%% Create outputs
y = {'input', ims};
if imdb.dataset.annotation.hasPixelLabels
    y = [y, {'label', labels}];
end
if imdb.weaklySupervised
    y = [y, {'labelsImage', labelsImage}];
end

% Instance/pixel weights, can be left empty
y = [y, {'classWeights', opts.classWeights}];

% Decide which level of supervision to pick
if imdb.semiSupervised
    isWeaklySupervised = ~imdb.images.isFullySupervised(images);
    if isWeaklySupervised
        assert(imdb.dataset.annotation.hasPixelLabels);
    end
    y = [y, {'isWeaklySupervised', isWeaklySupervised}];
end