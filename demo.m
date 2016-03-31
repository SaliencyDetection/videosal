clc
clear

addpath( genpath( '.' ) );
foldername = fileparts( mfilename( 'fullpath' ) );

options.valScale = 60;
options.alpha = 0.05;
options.color_size = 5;
%% Print status messages on screen
options.vocal = true;
options.regnum =500;
options.m = 20;
options.gradLambda = 1;
videoFiles = dir(fullfile(foldername, 'data', 'input'));
videoNUM = length(videoFiles)-2;


for videonum = 1:videoNUM
    videofolder =  videoFiles(videonum+2).name;
    options.infolder = fullfile( foldername, 'data', 'input',videofolder );
    % The folder where all the outputs will be stored.
    options.outfolder = fullfile( foldername, 'data', 'output', videofolder );
    if( ~exist( options.outfolder, 'dir' ) )
        mkdir( options.outfolder ),
    end;
    if( ~exist( fullfile( options.outfolder, 'energy'), 'dir' ) )
        mkdir(fullfile( options.outfolder, 'energy'));
    end
    if( ~exist( fullfile( options.outfolder, 'saliency'), 'dir' ) )
        mkdir(fullfile( options.outfolder, 'saliency'));
    end
    % Cache all frames in memory
    [data.frames,data.names,height,width,nframe ]= readAllFrames( options );
    
     % Load optical flow (or compute if file is not found)
    data.flow = loadFlow( options );
    if( isempty( data.flow ) )
        data.flow = computeOpticalFlow( options, data.frames );
    end
    
    % Load superpixels (or compute if not found)
    data.superpixels = loadSuperpixels( options );
    if( isempty( data.superpixels ) )
        data.superpixels = computeSuperpixels(  options, data.frames );
    end
    [ superpixels, nodeFrameId, bounds, labels ] = makeSuperpixelIndexUnique( data.superpixels );
    [ colours, centres, t ] = getSuperpixelStats( data.frames(1:nframe-1), superpixels, double(labels) );%
    
    valLAB = [];
    for index = 1:nframe-1
        valLAB = [valLAB;data.superpixels{index}.Sup1, data.superpixels{index}.Sup2, data.superpixels{index}.Sup3];     
    end
    RegionSal = [];
    frameEnergy = cell( nframe-1, 1 );

    foregroundArea = 0;
    for index = 1:nframe-1        
        frame = data.frames{index};        
        frameName = data.names{index};    
        nLabel = max(data.superpixels{index}.Label(:));
        Label = data.superpixels{index}.Label;
        framex = reshape(frame,height*width,1,3);
        Label = reshape(Label,height*width,1);       
        frameVal = colours(bounds(index):bounds(index+1)-1,:);
        framex = uint8(reshape(superpixel2pixel(double(data.superpixels{index}.Label),double(frameVal)),height ,width,3));       
        framex=imfilter(framex,fspecial('average',3),'same','replicate');
        G = edge_detect(framex);%static boundary

        gradient = getFlowGradient( data.flow{index} );
        magnitude = getMagnitude( gradient );

        if index>1
            mask = imdilate((frameEnergy{index-1}>0.3),strel('diamond',30))+0.3;
            mask(mask(:)>1)=1;
            magnitude = magnitude.*mask;
            G = G.*mask;
        end

        gradBoundary = 1 - exp( -options.gradLambda * magnitude );        
        
        if (max(magnitude(:))<10)
            gradBoundary = gradBoundary + 0.01;
        end
        
        G = G.*( gradBoundary );%spatio-temporal gradient
        
        %% saliency via gradient flow
        [V_Energy1 H_Energy1 V_Energy2 H_Energy2] = energy_map(double(framex),double(G));
        
        if index ==1
            Energy = min(min(min(H_Energy1,V_Energy1),H_Energy2),V_Energy2);       
        else
            mask = int32(imdilate((Energy>0.2),strel('diamond',20)));
            mask = ~mask;
            Energymap = (Energy<0.05).*mask; 
            Energymap = ~Energymap;
            Energy = Energy*0.3+(Energymap.*min(min(min(H_Energy1,V_Energy1),H_Energy2),V_Energy2))*0.7;%considering saliency of prior frame
        end
        
        Energy = Energy/max(Energy(:));         
        L{1} = uint32(data.superpixels{index}.Label);
        S{1} = repmat(Energy,[1 3]);
        [ R, ~, ~ ] = getSuperpixelStats(S(1:1),L, double(nLabel) );
        R = double(R(:,1));
        [sR,indexR] = sort(R);
        t = sum(sR(end-9:end))/10;
        R = (R-min(R))/(t-min(R));
        R(R>1)=1;
        RegionSal = [RegionSal;R];
        Energy = reshape(superpixel2pixel(double(data.superpixels{index}.Label),double(R)),height ,width); 
        imwrite(Energy, [options.outfolder '\energy\' 'initial_' frameName  '.bmp']);
        frameEnergy{index} = Energy;
        foregroundArea = foregroundArea + sum(sum(frameEnergy{index}>0.6));   
    end
    %% large salient object
    foregroundArea = foregroundArea/(nframe-1);
    if foregroundArea > height*width*0.02
        for index = 1:nframe-1
            Energymap = ones(height,width);
            Label = data.superpixels{index}.Label;
            if index ==1
                mask1 = int32(imdilate((frameEnergy{index}>0.4),strel('diamond',20)));
                mask1 = ~mask1;
                mask2 = int32(imdilate((frameEnergy{index+1}>0.4),strel('diamond',20)));
                mask2 = ~mask2;
                mask = mask1.*mask2;
                mask(1:end,1) = 1;
                mask(1:end,end) = 1;
                mask(1,1:end) = 1;
                mask(end,1:end) = 1;
                Energymap = Energymap.*mask;     
            else
                mask1 = int32(imdilate((frameEnergy{index}>0.4),strel('diamond',20)));
                mask1 = ~mask1;
                mask2 = int32(imdilate((frameEnergy{index-1}>0.4),strel('diamond',20)));
                mask2 = ~mask2;
                mask = mask1.*mask2;
                mask(1:end,1) = 1;
                mask(1:end,end) = 1;
                mask(1,1:end) = 1;
                mask(end,1:end) = 1;
                Energymap = Energymap.*mask;
            end
            labelnum = max(Label(:));
             [ ConSPix, ConSPix1, ConSPDouble ] = find_connect_superpixel_DoubleIn_Opposite( Label, labelnum, height ,width );
             
       %% background contrast%%%%%%%%%%%%%%%%
        EdgSup = int32(Energymap).*Label;
        EdgSup = unique(EdgSup(:));
        EdgSup(EdgSup==0) = [];
        foreground = ones(labelnum,1);
        foreground( EdgSup) = 0;
        background = zeros(labelnum,1);
        background( EdgSup) = 1;
     
            [edges_x edges_y] = find(triu(ConSPix1)>0);
            ConS = [edges_x edges_y];
            t = edges_x-edges_y;
            ConS(t==0,:) = [];
            DcolNor=sqrt(sum((valLAB(ConS(:,1)+bounds(index)-1,:)-valLAB(ConS(:,2)+bounds(index)-1,:)).^2,2));
            for i =1:size(ConS,1)
                if background(ConS(i,1))==1&&background(ConS(i,2))==1
                    DcolNor(i)=0.0001;
                end
            end
        WconFirst=sparse([ConS(:,1);ConS(:,2)],[ConS(:,2);ConS(:,1)], ...
             [ DcolNor; DcolNor],double(labelnum),double(labelnum))+ sparse(1:double(labelnum),1:double(labelnum),ones(labelnum,1));
        geoDis = graphallshortestpaths(WconFirst);
        geoDis(:,logical(foreground)) = [];
        geoDis(logical(background),:) = [];
        
        [edges_x edges_y] = find(triu(ones(labelnum,labelnum))>0);
        ConSPDouble = [edges_x edges_y];
        colorDis=sqrt(sum((valLAB(ConSPDouble(:,1)+bounds(index)-1,:)-valLAB(ConSPDouble(:,2)+bounds(index)-1,:)).^2,2));      
        colorDis=sparse([ConSPDouble(:,1);ConSPDouble(:,2)],[ConSPDouble(:,2);ConSPDouble(:,1)], ...
             [ colorDis; colorDis],double(labelnum),double(labelnum));
        colorDis = full(colorDis);
        colorDis(:,logical(foreground)) = [];
        colorDis(logical(background),:) = [];
        posDis=double(sqrt(sum((centres(ConSPDouble(:,1)+bounds(index)-1,:)-centres(ConSPDouble(:,2)+bounds(index)-1,:)).^2,2)));      
        posDis=sparse([ConSPDouble(:,1);ConSPDouble(:,2)],[ConSPDouble(:,2);ConSPDouble(:,1)], ...
             [ posDis; posDis],double(labelnum),double(labelnum));
        posDis = full(posDis);
        posDis(:,logical(foreground)) = [];
        posDis(logical(background),:) = [];
        u = 2*min(posDis')+0.001;
        u =  repmat(u',1,size(posDis,2));
        posDis = exp(-posDis./u);
        geoSal = normalize(sum(geoDis,2));%
        contrastSal = normalize(sum(colorDis.*posDis,2)./sum(posDis,2));%+
        foreSal = geoSal.*min(contrastSal,0.5);
        
        if  size(foreSal,1) > 40
            [sR,indexR] = sort(foreSal);
            t = sum(sR(end-4:end))/5;
        else
            [sR,indexR] = sort(foreSal);
            t = double(sum(sR(end-(int32(size(foreSal,1)*0.1))+1:end))/double((int32(size(foreSal,1)*0.1))));     
        end
        foreSal = (foreSal-min(foreSal))/(t-min(foreSal));
        foreSal(foreSal>1)=1;
        foreSal = normalize(foreSal);
        Sal = zeros(labelnum,1);
        Sal(logical(foreground))=foreSal;

        Sal = 0.3*RegionSal(bounds(index):bounds(index+1)-1) + 0.7*Sal;
        Energy = reshape(superpixel2pixel(double(Label),double(Sal)),height ,width); 
        imwrite(Energy, [options.outfolder '\energy\' 'ref_' data.names{index} '.bmp']);
        RegionSal(bounds(index):bounds(index+1)-1)=Sal;
        frameEnergy{index} = Energy;
        end
        clear EdgWcon I N WconFirst E iD P
    end
    
    
    %% Spatiotemporal consistency%%%%%%%%%%%%
        ConSPix = []; Conedge = [];         
        for index = 1:nframe-1
            Label = data.superpixels{index}.Label;
            [conSPix conedge]= find_connect_superpixel( Label, max(Label(:)), height ,width );      
            Conedge = [Conedge;conedge + bounds(index)-1];
        end
        intralength = size(Conedge,1);
        for index = 1:nframe-2
            [x y] = meshgrid(1:bounds(index+1)-bounds(index),1:bounds(index+2)-bounds(index+1));
            conedge = [x(:)+bounds(index)-1,y(:)+bounds(index+1)-1];
            connect = sum((centres(conedge(:,1),:) - centres(conedge(:,2),:)).^2,2 );
            Conedge = [Conedge;conedge(find(connect<800),:)];
        end

    valDistances=sqrt(sum((valLAB(Conedge(:,1),:)-valLAB(Conedge(:,2),:)).^2,2));
    valDistances(intralength+1:end)=valDistances(intralength+1:end)/5;
    valDistances=normalize(valDistances);
    weights=exp(-options.valScale*valDistances)+ 1e-5;
    weights=sparse([Conedge(:,1);Conedge(:,2)],[Conedge(:,2);Conedge(:,1)], ...
    [weights;weights],labels,labels);
    E = sparse(1:labels,1:labels,ones(labels,1)); iD = sparse(1:labels,1:labels,1./sum(weights));
    P = iD*weights;
    
    RegionSal = (E-P+10*options.alpha*E)\RegionSal;
    
   %% generating final saliency 
    for index = 1:nframe-1
        frameName = data.names{index};
        Label = data.superpixels{index}.Label;
        R = RegionSal(bounds(index):bounds(index+1)-1);
        [sR,indexR] = sort(R);
        t = sum(sR(end-9:end))/10;
        R = (R-min(R))/(t-min(R));
        R(R>1)=1;
        
        Energy = reshape(superpixel2pixel(double(Label),double(R)),height ,width); 
        imwrite(Energy, [options.outfolder '\saliency\' frameName '.bmp']);
    end

end

