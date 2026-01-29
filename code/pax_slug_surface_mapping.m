%%
clear all; close all;
%%
% set working directory and data directory
[scriptPath,~,ext] = fileparts(matlab.desktop.editor.getActiveFilename);

% Remove '/code' from filepath. If you change names or restructure
% directories, change this
parentDir = scriptPath(1:end-5);
dataDir = strcat(parentDir,'/raw_data');

% Define experiment description and create necessary directories
exp_description = '/pax_slug_stg13';
rep = '/rep1';
im_description = '/2024_04_18_slug_546_pax_647_stg_13_10x_001.nd2_1';
imDir = strcat(dataDir,exp_description,rep);
mkdir(imDir, im_description);
mkdir(fullfile(imDir, im_description), 'projectFiles');
projectDir = fullfile(imDir, im_description, 'projectFiles');
mkdir(fullfile(projectDir), 'mapping');
%%
% cd to image directory
cd(imDir)

% Create experiment
xp = project.Experiment(projectDir, imDir);

%%
% set file meta data
fileMeta                 = struct();
fileMeta.dataDir         = imDir;
fileMeta.filenameFormat  = '2024_04_18_slug_546_pax_647_stg_13_10x_001.nd2_1.tif';
fileMeta.timePoints      = [1]; 
fileMeta.stackResolution = [0.5274 0.5274 0.3448]; % voxels/micron
fileMeta.swapZT          = 0; % for full time series use 1;
fileMeta.nChannels       = 3;
fileMeta.stackSize       = [512 512 59 3]; % x, y, z, c

%%
% set experiment meta data
expMeta                  = struct();
expMeta.channelsUsed     = [1:3];
expMeta.channelColor     = [1:3];
expMeta.description      = exp_description;
expMeta.dynamicSurface   = 0; % 1 if surface morphology changes with time
expMeta.jitterCorrection = 0; % 1: Correct for sample translation
expMeta.fitTime          = fileMeta.timePoints(1); 
% Set surface detector and fitter types 
expMeta.detectorType     = 'surfaceDetection.planarEdgeDetector';
expMeta.fitterType       = 'surfaceFitting.tpsFitter'; 

xp.setFileMeta(fileMeta);
xp.setExpMeta(expMeta);

%%
% load time, rescale aspect ratio
xp.initNew();
xp.loadTime(1);  


%%
xp.rescaleStackToUnitAspect();

%%
% set detector options
detectOptions = xp.detector.defaultOptions;
detectOptions.sigma = 7; % variance of Gaussian blur
detectOptions.zdir = 3; % step through -z direction to detect surface
detectOptions.channels = [1]; % choose which channels to use for edge detection
detectOptions.maxIthresh = 0.01;
detectOptions.summedIthresh = 0.03; 
detectOptions.sigZoutliers = 1;
detectOptions.scaleZoutliers = 5;
detectOptions.seedDistance = 5;



% Calling detectSurface runs the surface detector and creates the point
% cloud in detector.pointCloud.

xp.setDetectOptions(detectOptions);
xp.detectSurface();

% inspect initial surface detection
imshow(xp.detector.mask.*xp.detector.surfaceMatrix, [],...
                                            'InitialMagnification', 40);

%% 
% One can then find better filter parameters without redetecting the
% surface by changing the second block of options in detectOptions and 
% calling resetMask and applyMasks. 

xp.detector.resetMask();

detectOptions.maxIthresh = 0.01;
detectOptions.summedIthresh = 0.03;
detectOptions.sigZoutliers = 10; % remove height outliers
detectOptions.scaleZoutliers = 30; % spatial scale of height threhsold

xp.detector.setOptions(detectOptions); 
xp.detector.applyMasks();

% reinspect detection
imshow(xp.detector.mask.*xp.detector.surfaceMatrix, [],...
                                            'InitialMagnification', 40); 

%%
% inspect point cloud
ssfactor = 5; % sub-sampling factor
xp.detector.pointCloud.inspect(ssfactor);

%%
% Fit surface
fitOptions = struct('smoothing', 500, 'gridSize', [100 100]);
xp.setFitOptions(fitOptions);
xp.fitSurface();


%%
% Inspect surface fit; change dimension and value to re-slice image at
% different pixel locations
inspectOptions= struct('dimension', 'x', 'value', 400, 'pointCloud', 'c');

xp.fitter.inspectQuality(inspectOptions, xp.detector, xp.stack);

%%
% This shifts the detected surface so that it better aligns with nuclei
shift = -8;
xp.normallyEvolve(shift);

xp.fitter.inspectQuality(inspectOptions, xp.detector, xp.stack);


%%
% Generate surface of interest
xp.generateSOI();

%%
% Pullback the stack to the desired charts
%
% Pass the region of interest and the current time to pull back the stack
% in the desired charts. This generates the data fields containing the
% pullback.
%
% ROI needs to be empty because we chose to work with unaligned points to
% generate meshes

% set the multilayer options; 
multiLayerOpts = struct('nLayers', 31, 'layerDistance', 1, 'sigma', 0, ...
    'makeIP', false, 'zevolve', false, 'IPonly', false);
ROI = [];
xp.SOI.pullbackStack(xp.stack, ROI, xp.currentTime,multiLayerOpts);

%%
% Now we extract the data field from the surface of interest at the current
% time, which is the time of the fit.
data = xp.SOI.getField('data');
data = data(xp.tIdx(xp.currentTime));
figure 
i = 1;
type = 'xy';
patchName     = [type '_index'];
transformName = type;
pb = data.getPatch(patchName).getTransform(transformName).apply{1};
imshow(pb',[],'InitialMagnification',66)

%%
% Show the distortion in the map as measured by the strain, defined in
% the supplementary information (difference between Cartesian metric and
% actual metric). Blue is compression, red is extension. 

chartName = 'xy';
gridSize = [20 20];
strainScale = 30;
plotMetricStrain(xp.SOI, chartName, gridSize, strainScale)

%%
% Save metric tensor for later area/distance measurements
gti = 1;
chart     = xp.SOI.atlas(gti).getChart(chartName);
domName   = chart.domain.name;
g         = xp.SOI.getField('metric');

%if isempty(g(gti).patches)
%  xp.SOI.NCalcInducedMetric(gti);
%end

g         = g(gti).getPatch(domName).getTransform(chartName);

metric = g.apply();


saveDir = fullfile(projectDir, 'mapping/metric.mat');
save(saveDir, 'metric');


%% Save the surface of interest to disc
%
% Here we save the SOI using SOI.save. We set the following options:
%
% * dir:            The directory to save the SOI to.
% * imwriteOptions: Pullbacks are saved to image files using imwrite, we
% can pass options to change file format, compression etc. For example we
% could change this option to
% imwriteOptions = {'jp2', 'Mode', 'lossless'}; 
% * make8bit:       Often absolute intensities don't matter and 8 bit offers
% a large enough dynamic range. This options rescales the lookup table and
% converts to 8 bit before saving.
%
imwriteOptions = {'tif'};
saveDir = fullfile(projectDir, 'mapping');

options = struct('dir',saveDir,'imwriteOptions',{imwriteOptions},...
                    'make8bit',false);
%xp.SOI.save(options)
xp.SOI.multilayer2stack(1, saveDir);
