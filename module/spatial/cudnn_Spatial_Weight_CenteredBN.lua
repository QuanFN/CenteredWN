--[[
-- --This file implements Centered linear module, which wraps Centered weight normalization
--   --into the SpationConvolution of cudnn.
--       --
--         --The code is based on the orignial Torch implemantation of SpationConvolution for cudnn.
--          -- -------------------------------------------------------------------
--  --Author: Lei Huang
--   --mail: huanglei@nlsde.buaa.edu.cn
--]]

local Spatial_Weight_CenteredBN, parent =
    torch.class('cudnn.Spatial_Weight_CenteredBN', 'nn.SpatialConvolution')
local ffi = require 'ffi'
local find = require 'cudnn.find'
local errcheck = cudnn.errcheck
local checkedCall = find.checkedCall

function Spatial_Weight_CenteredBN:__init(nInputPlane, nOutputPlane,
                            kW, kH, dW, dH, padW, padH)
    local delayedReset = self.reset
    self.reset = function() end
    parent.__init(self, nInputPlane, nOutputPlane, kW, kH, dW, dH)
    self.reset = delayedReset
    self.padW = padW or 0
    self.padH = padH or 0
    self.groups = 1
    assert(nInputPlane % self.groups == 0,
           'nInputPlane should be divisible by nGroups')
    assert(nOutputPlane % self.groups == 0,
           'nOutputPlane should be divisible by nGroups')
    self.weight = torch.Tensor(nOutputPlane, nInputPlane/self.groups, kH, kW)
    self.gradWeight = torch.Tensor(nOutputPlane, nInputPlane/self.groups, kH, kW)
   
    self.W = torch.Tensor(nOutputPlane, nInputPlane/self.groups, kH, kW)
    self.gradW = torch.Tensor(nOutputPlane, nInputPlane/self.groups, kH, kW)
    self.eps=1e-3
    self:reset()
    -- should nil for serialization, the reset will still work
    self.reset = nil
    self.isTraining=true
end

-- if you change the configuration of the module manually, call this
function Spatial_Weight_CenteredBN:resetWeightDescriptors(desc)
    -- for compatibility
    self.groups = self.groups or 1
    assert(cudnn.typemap[torch.typename(self.W)], 'Only Cuda supported duh!')
    assert(cudnn.typemap[torch.typename(self.bias)] or not self.bias, 'Only Cuda supported duh!')

    -- create descriptor for bias
    if self.bias then
        self.biasDesc = cudnn.toDescriptor(self.bias:view(1, self.nOutputPlane,1,1))
    end

    self.WDesc = cudnn.setFilterDescriptor(
       { dataType = cudnn.typemap[torch.typename(self.W)],
         filterDimA = desc or
            {self.nOutputPlane/self.groups,
             self.nInputPlane/self.groups,
             self.kH, self.kW}
       }
    )

    return self
end

function Spatial_Weight_CenteredBN:fastest(mode)
    if mode == nil then mode = true end
    if not self.fastest_mode or self.fastest_mode ~= mode then
       self.fastest_mode = mode
       self.iDesc = nil
    end
    return self
end

function Spatial_Weight_CenteredBN:setMode(fmode, bdmode, bwmode)
    if fmode ~= nil then
        self.fmode = fmode
    end
    if bdmode ~= nil then
        self.bdmode = bdmode
    end
    if bwmode ~= nil then
        self.bwmode = bwmode
    end
    self.iDesc = nil
    return self
end

function Spatial_Weight_CenteredBN:resetMode()
    self.fmode = nil
    self.bdmode = nil
    self.bwmode = nil
    return self
end

function Spatial_Weight_CenteredBN:noBias()
   self.bias = nil
   self.gradBias = nil
   return self
end


function Spatial_Weight_CenteredBN:checkInputChanged(input)
    assert(input:isContiguous(),
           "input to " .. torch.type(self) .. " needs to be contiguous, but is non-contiguous")
    if not self.iSize or self.iSize:size() ~= input:dim() then
       self.iSize = torch.LongStorage(input:dim()):fill(0)
    end
    self.groups = self.groups or 1
    if not self.WDesc then self:resetWeightDescriptors() end
    if not self.WDesc then error "Weights not assigned!" end

    if not self.iDesc or not self.oDesc or input:size(1) ~= self.iSize[1] or input:size(2) ~= self.iSize[2]
    or input:size(3) ~= self.iSize[3] or input:size(4) ~= self.iSize[4] or (input:dim()==5 and input:size(5) ~= self.iSize[5]) then
       self.iSize = input:size()
       assert(self.nInputPlane == input:size(2),
              'input has to contain: '
                 .. self.nInputPlane
                 .. ' feature maps, but received input of size: '
                 .. input:size(1) .. ' x ' .. input:size(2) .. ' x ' .. input:size(3)
                 .. (input:dim()>3 and ' x ' .. input:size(4) ..
                        (input:dim()==5 and ' x ' .. input:size(5) or '') or ''))
       return true
    end
    return false
end

function Spatial_Weight_CenteredBN:createIODescriptors(input)
   local batch = true
   if input:dim() == 3 then
      input = input:view(1, input:size(1), input:size(2), input:size(3))
      batch = false
   end
   if Spatial_Weight_CenteredBN.checkInputChanged(self, input) then
        -- create input descriptor
        local input_slice = input:narrow(2,1,self.nInputPlane/self.groups)
        self.iDesc = cudnn.toDescriptor(input_slice)
        -- create conv descriptor
        self.padH, self.padW = self.padH or 0, self.padW or 0
        -- those needed to calculate hash
        self.pad = {self.padH, self.padW}
        self.stride = {self.dH, self.dW}

        self.convDescData = { padA = self.pad,
             filterStrideA = self.stride,
             upscaleA = {1,1},
             dataType = cudnn.configmap(torch.type(self.W))
        }

        self.convDesc = cudnn.setConvolutionDescriptor(self.convDescData)

        -- get output shape, resize output
        local oSize = torch.IntTensor(4)
        errcheck('cudnnGetConvolutionNdForwardOutputDim',
                 self.convDesc[0], self.iDesc[0],
                 self.WDesc[0], 4, oSize:data())
        oSize[2] = oSize[2] * self.groups
        self.output:resize(oSize:long():storage())
        self.oSize = self.output:size()

        local output_slice = self.output:narrow(2,1,self.nOutputPlane/self.groups)
        -- create descriptor for output
        self.oDesc = cudnn.toDescriptor(output_slice)
        self.oDescForBias = cudnn.toDescriptor(self.output)

        find:prepare(self, input_slice, output_slice)

        -- create offsets for groups
        local iH, iW = input:size(3), input:size(4)
        local kH, kW = self.kH, self.kW
        local oH, oW = oSize[3], oSize[4]
        self.input_offset = self.nInputPlane / self.groups * iH * iW
        self.output_offset = self.nOutputPlane / self.groups * oH * oW
        self.W_offset = self.nInputPlane / self.groups * self.nOutputPlane / self.groups * kH * kW

        if not batch then
            self.output = self.output:view(self.output:size(2),
                                           self.output:size(3),
                                           self.output:size(4))
        end

   end
   return self
end

local function makeContiguous(self, input, gradOutput)
   if not input:isContiguous() then
      self._input = self._input or input.new()
      self._input:typeAs(input):resizeAs(input):copy(input)
      input = self._input
   end
   if gradOutput and not gradOutput:isContiguous() then
      self._gradOutput = self._gradOutput or gradOutput.new()
      self._gradOutput:typeAs(gradOutput):resizeAs(gradOutput):copy(gradOutput)
      gradOutput = self._gradOutput
   end
   return input, gradOutput
end



-- function to re-view the weight layout in a way that would make the MM ops happy
local function viewWeight(self)
   self.weight = self.weight:view(self.nOutputPlane, self.nInputPlane * self.kH * self.kW)
end

local function unviewWeight(self)
   self.weight = self.weight:view(self.nOutputPlane, self.nInputPlane, self.kH, self.kW)
end

-- function to re-view the weight layout in a way that would make the MM ops happy
local function viewGradWeight(self)
   if self.gradWeight and self.gradWeight:dim() > 0 then
      self.gradWeight = self.gradWeight:view(self.nOutputPlane, self.nInputPlane * self.kH * self.kW)
   end
end

local function unviewGradWeight(self)
   if self.gradWeight and self.gradWeight:dim() > 0 then
      self.gradWeight = self.gradWeight:view(self.nOutputPlane, self.nInputPlane, self.kH, self.kW)
   end
end
-- function to re-view the weight layout in a way that would make the MM ops happy
local function viewW(self)
   self.W = self.W:view(self.nOutputPlane, self.nInputPlane * self.kH * self.kW)
end

local function unviewW(self)
   self.W = self.W:view(self.nOutputPlane, self.nInputPlane, self.kH, self.kW)
end

-- function to re-view the weight layout in a way that would make the MM ops happy
local function viewGradW(self)
   if self.gradW and self.gradW:dim() > 0 then
      self.gradW = self.gradW:view(self.nOutputPlane, self.nInputPlane * self.kH * self.kW)
   end
end

local function unviewGradW(self)
   if self.gradW and self.gradW:dim() > 0 then
      self.gradW = self.gradW:view(self.nOutputPlane, self.nInputPlane, self.kH, self.kW)
   end
end



function Spatial_Weight_CenteredBN:updateOutput(input)
    input = makeContiguous(self, input)
    self:createIODescriptors(input)

 if self.isTraining then   
    -----------------------------transform----------------------
    -- train mode, do the forward from the weight. when finish training, remove the unnecessary Tensors e.g. self.weight by calling :endTraining. 
    viewWeight(self)
   viewW(self)
   local n_output=self.weight:size(1)
   local n_input=self.weight:size(2)

   self.buffer = self.buffer or input.new()
   self.buffer2 = self.buffer2 or input.new()
   self.centered = self.centered or input.new()
   self.mean=self.mean or input.new()
   self.std=self.std or input.new()
  
        self.mean=self.mean or input.new()
              self.std=self.std or input.new()

    self.W=self.W or input.new()
    self.W:resizeAs(self.weight)
     self.mean:mean(self.weight, 2)
    self.weight:add(-self.mean:expand(n_output,n_input))
   self.std:resize(n_output,1):copy(self.weight:norm(2,2)):pow(-1)
  self.W:copy(self.weight):cmul(self.std:expand(n_output,n_input))

  unviewW(self)
   unviewWeight(self)
 end
     ------------------------------------------------cudnn excute-----------------------

    local finder = find.get()
    local fwdAlgo = finder:forwardAlgorithm(self, { self.iDesc[0], self.input_slice, self.WDesc[0],
                                                    self.W, self.convDesc[0], self.oDesc[0], self.output_slice})
    local extraBuffer, extraBufferSize = cudnn.getSharedWorkspace()
    for g = 0, self.groups - 1 do
        checkedCall(self,'cudnnConvolutionForward', cudnn.getHandle(),
                    cudnn.scalar(input, 1),
                    self.iDesc[0], input:data() + g*self.input_offset,
                    self.WDesc[0], self.W:data() + g*self.W_offset,
                    self.convDesc[0], fwdAlgo,
                    extraBuffer, extraBufferSize,
                    cudnn.scalar(input, 0),
                    self.oDesc[0], self.output:data() + g*self.output_offset);
    end


    -- add bias
    if self.bias then
        errcheck('cudnnAddTensor', cudnn.getHandle(),
                 cudnn.scalar(input, 1), self.biasDesc[0], self.bias:data(),
                 cudnn.scalar(input, 1), self.oDescForBias[0], self.output:data())
    end
    return self.output
end

function Spatial_Weight_CenteredBN:updateGradInput(input, gradOutput)
    if not self.gradInput then return end
    self.gradInput:resizeAs(input)
    assert(gradOutput:dim() == input:dim()-1 or gradOutput:dim() == input:dim()
              or (gradOutput:dim()==5 and input:dim()==4), 'Wrong gradOutput dimensions');
    input, gradOutput = makeContiguous(self, input, gradOutput)
    self:createIODescriptors(input)
    local finder = find.get()
    local bwdDataAlgo = finder:backwardDataAlgorithm(self, { self.WDesc[0], self.W, self.oDesc[0],
                                                             self.output_slice, self.convDesc[0], self.iDesc[0], self.input_slice })
    local extraBuffer, extraBufferSize = cudnn.getSharedWorkspace()
    for g = 0,self.groups - 1 do
        checkedCall(self,'cudnnConvolutionBackwardData', cudnn.getHandle(),
                    cudnn.scalar(input, 1),
                    self.WDesc[0], self.W:data() + g*self.W_offset,
                    self.oDesc[0], gradOutput:data() + g*self.output_offset,
                    self.convDesc[0],
                    bwdDataAlgo,
                    extraBuffer, extraBufferSize,
                    cudnn.scalar(input, 0),
                    self.iDesc[0], self.gradInput:data() + g*self.input_offset)
    end
    return self.gradInput
end

function Spatial_Weight_CenteredBN:accGradParameters(input, gradOutput, scale)
    self.scaleT = self.scaleT or self.W.new(1)
    -- this line forces this member to always be on CPU (needed for cudnn)
    self.scaleT = torch.type(self.W) == 'torch.CudaDoubleTensor'
       and self.scaleT:double() or self.scaleT:float()
    scale = scale or 1.0
    self.scaleT[1] = scale
    input, gradOutput = makeContiguous(self, input, gradOutput)
    self:createIODescriptors(input)
   self.gradW:fill(0)

    local finder = find.get()
    local bwdFilterAlgo = finder:backwardFilterAlgorithm(self, { self.iDesc[0], self.input_slice, self.oDesc[0],
                                                               self.output_slice, self.convDesc[0], self.WDesc[0], self.W})

    -- gradBias
    if self.bias then
        errcheck('cudnnConvolutionBackwardBias', cudnn.getHandle(),
                 self.scaleT:data(),
                 self.oDescForBias[0], gradOutput:data(),
                 cudnn.scalar(input, 1),
                 self.biasDesc[0], self.gradBias:data())
    end

    local extraBuffer, extraBufferSize = cudnn.getSharedWorkspace()
    for g = 0, self.groups - 1 do
        -- gradWeight
       checkedCall(self,'cudnnConvolutionBackwardFilter', cudnn.getHandle(),
                   self.scaleT:data(),
                   self.iDesc[0], input:data() + g*self.input_offset,
                   self.oDesc[0], gradOutput:data() + g*self.output_offset,
                   self.convDesc[0],
                   bwdFilterAlgo,
                   extraBuffer, extraBufferSize,
                   cudnn.scalar(input, 1),
                   self.WDesc[0], self.gradW:data() + g*self.W_offset);
    end




-----------------------------transform--------------------------

    
   viewWeight(self)
   viewW(self)
   viewGradWeight(self)
   viewGradW(self)
    local n_output=self.weight:size(1)
     local n_input=self.weight:size(2)


     self.gradWeight:cmul(self.W, self.gradW)
     self.mean:sum(self.gradWeight,2)
   self.gradWeight:copy(-self.W):cmul(self.mean:expand(n_output,n_input))

     self.mean:mean(self.gradW,2)
    self.gradWeight:add(self.gradW):add(-self.mean:expand(n_output,n_input))
   self.gradWeight:cmul(self.std:expand(n_output,n_input))

   unviewWeight(self)
   unviewW(self)
   unviewGradWeight(self)
   unviewGradW(self)


    return self.gradOutput
end

function Spatial_Weight_CenteredBN:clearDesc()
    self.WDesc = nil
    self.biasDesc = nil
    self.convDesc = nil
    self.iDesc = nil
    self.oDesc = nil
    self.oDescForBias = nil
    self.oSize = nil
    self.scaleT = nil
    return self
end

function Spatial_Weight_CenteredBN:write(f)
    self:clearDesc()
    local var = {}
    for k,v in pairs(self) do
        var[k] = v
    end
    f:writeObject(var)
end

function Spatial_Weight_CenteredBN:clearState()
   self:clearDesc()
   nn.utils.clear(self, '_input', '_gradOutput', 'input_slice', 'output_slice')
   return nn.Module.clearState(self)
end

function Spatial_Weight_CenteredBN:endTraining()
    viewWeight(self)
     viewW(self)
      local n_output=self.weight:size(1)
     local n_input=self.weight:size(2)

     self.buffer:mean(self.weight, 2)
     self.buffer2:repeatTensor(self.buffer, 1, n_input)
     self.centered:add(self.weight, -1, self.buffer2)
    self.std:resize(n_output,1):copy(self.centered:norm(2,2)):pow(-1)
    self.W:repeatTensor(self.std,1,n_input)
     self.W:cmul(self.centered)

     unviewW(self)
    unviewWeight(self)
     
    self.isTraining=false
    ------clear buffer-----------------
    self.weight:set()
    self.buffer:set()
    self.buffer2:set()
    self.centered:set()
    self.std:set()
    self.gradWeight:set()
    self.gradW:set()
    
--    self.weight=nil
--    self.buffer=nil
--    self.buffer2=nil
--    self.centered=nil
--    self.std=nil
--    self.gradWeight=nil
--    self.gradW=nil
    return
end
